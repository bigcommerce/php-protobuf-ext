// Protocol Buffers - Google's data interchange format
// Copyright 2008 Google Inc.  All rights reserved.
//
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file or at
// https://developers.google.com/open-source/licenses/bsd

#include "protobuf.h"

#include <Zend/zend_interfaces.h>
#include <php.h>

#include "arena.h"
#include "array.h"
#include "convert.h"
#include "def.h"
#include "map.h"
#include "message.h"
#include "names.h"
#include "print_options.h"

// -----------------------------------------------------------------------------
// Module "globals"
// -----------------------------------------------------------------------------

// Despite the name, module "globals" are really thread-locals:
//  * PROTOBUF_G(var) accesses the thread-local variable for 'var'. Either:
//    * PROTOBUF_G(var) -> protobuf_globals.var (Non-ZTS / non-thread-safe)
//    * PROTOBUF_G(var) -> <Zend magic>         (ZTS / thread-safe builds)

#define PROTOBUF_G(v) ZEND_MODULE_GLOBALS_ACCESSOR(protobuf, v)

// Pool cache entry for keyed multi-pool support.
typedef struct {
  char* key;                // strdup'd, persistent
  upb_DefPool* symtab;
  HashTable name_msg_cache; // persistent=1
  HashTable name_enum_cache; // persistent=1
} pool_cache_entry;

// clang-format off
ZEND_BEGIN_MODULE_GLOBALS(protobuf)
  // Set by the user to make the descriptor pool persist between requests.
  zend_bool keep_descriptor_pool_after_request;

  // Set by the user to make the descriptor pool persist between requests.
  zend_class_entry* constructing_class;

  // A upb_DefPool that we are saving for the next request so that we don't have
  // to rebuild it from scratch. When keep_descriptor_pool_after_request==true,
  // we steal the upb_DefPool from the global DescriptorPool object just before
  // destroying it.
  upb_DefPool* global_symtab;

  // Object cache (see interface in protobuf.h).
  HashTable object_cache;

  // Name cache (see interface in protobuf.h).
  HashTable name_msg_cache;
  HashTable name_enum_cache;

  // An array of descriptor objects constructed during this request. These are
  // logically referenced by the corresponding class entry, but since we can't
  // actually write a class entry destructor, we reference them here, to be
  // destroyed on request shutdown.
  HashTable descriptors;

  // Keyed multi-pool cache: allows multiple descriptor pools to coexist,
  // each keyed by a per-request string (e.g., release name). Every persistent
  // pool lives in pool_cache -- the unkeyed keep_descriptor_pool_after_request
  // pool is simply the entry with key "".
  char* descriptor_pool_key;      // INI string, managed by Zend
  pool_cache_entry* pool_cache;   // malloc'd array of cached pools
  int pool_cache_count;           // number of entries in pool_cache

  // The lifecycle decision for the current request, recorded once in RINIT and
  // consumed by RSHUTDOWN: index of the pool_cache entry this request runs on,
  // or -1 for a request-local (non-persistent) pool. RSHUTDOWN must never
  // re-read the INI settings -- both are PHP_INI_ALL, and ini_set() values are
  // still in effect during RSHUTDOWN (zend_ini_deactivate runs later), so a
  // mid-request ini_set() could otherwise desynchronize setup from teardown
  // and free a pool the cache still references.
  int active_pool_idx;
ZEND_END_MODULE_GLOBALS(protobuf)
// clang-format on

void free_protobuf_globals(zend_protobuf_globals* globals) {
  zend_hash_destroy(&globals->name_msg_cache);
  zend_hash_destroy(&globals->name_enum_cache);
  // upb_DefPool_Free is not NULL-safe; global_symtab can be NULL if
  // upb_DefPool_New failed in RINIT.
  if (globals->global_symtab) {
    upb_DefPool_Free(globals->global_symtab);
  }
  globals->global_symtab = NULL;
}

ZEND_DECLARE_MODULE_GLOBALS(protobuf)

upb_DefPool* get_global_symtab() { return PROTOBUF_G(global_symtab); }

// This is a PHP extension (not a Zend extension). What follows is a summary of
// a PHP extension's lifetime and when various handlers are called.
//
//  * PHP_GINIT_FUNCTION(protobuf) / PHP_GSHUTDOWN_FUNCTION(protobuf)
//    are the constructor/destructor for the globals. The sequence over the
//    course of a process lifetime is:
//
//    # Process startup
//    GINIT(<Main Thread Globals>)
//    MINIT
//
//    foreach request:
//      RINIT
//        # Request is processed here.
//      RSHUTDOWN
//
//    foreach thread:
//      GINIT(<This Thread Globals>)
//        # Code for the thread runs here.
//      GSHUTDOWN(<This Thread Globals>)
//
//    # Process Shutdown
//    #
//    # These should be running per the docs, but I have not been able to
//    # actually get the process-wide shutdown functions to run.
//    #
//    # MSHUTDOWN
//    # GSHUTDOWN(<Main Thread Globals>)
//
//  * Threads can be created either explicitly by the user, inside a request,
//    or implicitly by the runtime, to process multiple requests concurrently.
//    If the latter is being used, then the "foreach thread" block above
//    actually looks like this:
//
//    foreach thread:
//      GINIT(<This Thread Globals>)
//      # A non-main thread will only receive requests when using a threaded
//      # MPM with Apache
//      foreach request:
//        RINIT
//          # Request is processed here.
//        RSHUTDOWN
//      GSHUTDOWN(<This Thread Globals>)
//
// That said, it appears that few people use threads with PHP:
//   * The pthread package documented at
//     https://www.php.net/manual/en/class.thread.php nas not been released
//     since 2016, and the current release fails to compile against any PHP
//     newer than 7.0.33.
//     * The GitHub master branch supports 7.2+, but this has not been released
//       to PECL.
//     * Its owner has disavowed it as "broken by design" and "in an untenable
//       position for the future":
//       https://github.com/krakjoe/pthreads/issues/929
//   * The only way to use PHP with requests in different threads is to use the
//     Apache 2 mod_php with the "worker" MPM. But this is explicitly
//     discouraged by the documentation: https://serverfault.com/a/231660

static PHP_GSHUTDOWN_FUNCTION(protobuf) {
  if (protobuf_globals->pool_cache_count > 0) {
    for (int i = 0; i < protobuf_globals->pool_cache_count; i++) {
      zend_hash_destroy(&protobuf_globals->pool_cache[i].name_msg_cache);
      zend_hash_destroy(&protobuf_globals->pool_cache[i].name_enum_cache);
      if (protobuf_globals->pool_cache[i].symtab) {
        upb_DefPool_Free(protobuf_globals->pool_cache[i].symtab);
      }
      free(protobuf_globals->pool_cache[i].key);
    }
    free(protobuf_globals->pool_cache);
    protobuf_globals->pool_cache = NULL;
    protobuf_globals->pool_cache_count = 0;
    protobuf_globals->global_symtab = NULL; /* was freed as part of a cache entry */
  } else if (protobuf_globals->global_symtab) {
    // Defensive: RSHUTDOWN always frees or NULLs global_symtab, so this is
    // normally unreachable.
    free_protobuf_globals(protobuf_globals);
  }
}

static PHP_GINIT_FUNCTION(protobuf) {
  protobuf_globals->global_symtab = NULL;
  protobuf_globals->pool_cache = NULL;
  protobuf_globals->pool_cache_count = 0;
  protobuf_globals->active_pool_idx = -1;
}

// Returns the index of the cache entry for `key`, or -1 if absent.
static int pool_cache_find(const char* key) {
  for (int i = 0; i < PROTOBUF_G(pool_cache_count); i++) {
    if (strcmp(PROTOBUF_G(pool_cache)[i].key, key) == 0) return i;
  }
  return -1;
}

// Appends an entry for `key` (symtab/name caches left for the caller to fill)
// and returns its index, or -1 on allocation failure. pool_cache_count is only
// incremented once every fallible step has succeeded, so the array and count
// can never disagree.
static int pool_cache_insert(const char* key) {
  pool_cache_entry* grown =
      realloc(PROTOBUF_G(pool_cache),
              (PROTOBUF_G(pool_cache_count) + 1) * sizeof(pool_cache_entry));
  if (!grown) return -1;
  PROTOBUF_G(pool_cache) = grown;

  char* key_copy = strdup(key);
  if (!key_copy) return -1;  // array stays grown; count unchanged -- harmless

  int idx = PROTOBUF_G(pool_cache_count)++;
  PROTOBUF_G(pool_cache)[idx].key = key_copy;
  return idx;
}

/**
 * PHP_RINIT_FUNCTION(protobuf)
 *
 * This function is run at the beginning of processing each request.
 */
static PHP_RINIT_FUNCTION(protobuf) {
  // The INI settings are sampled exactly once, here; the decision is recorded
  // in active_pool_idx and consumed by RSHUTDOWN. A mid-request ini_set() of
  // either setting therefore has no effect on the pool lifecycle.
  PROTOBUF_G(active_pool_idx) = -1;

  if (PROTOBUF_G(keep_descriptor_pool_after_request)) {
    // Persistent mode: the pool for this request lives in pool_cache, looked up
    // by descriptor_pool_key; the unkeyed persistent pool is the entry with key
    // "". Cached pools are persistent (persistent=1) and freed only in
    // GSHUTDOWN, never in RSHUTDOWN.
    char* key = PROTOBUF_G(descriptor_pool_key);
    if (!key) key = "";

    int idx = pool_cache_find(key);
    if (idx >= 0) {
      // Cache HIT: swap in the cached pool.
      PROTOBUF_G(global_symtab) = PROTOBUF_G(pool_cache)[idx].symtab;
      PROTOBUF_G(name_msg_cache) = PROTOBUF_G(pool_cache)[idx].name_msg_cache;
      PROTOBUF_G(name_enum_cache) = PROTOBUF_G(pool_cache)[idx].name_enum_cache;
      PROTOBUF_G(active_pool_idx) = idx;
    } else {
      // Cache MISS: create a fresh pool and register it.
      PROTOBUF_G(global_symtab) = upb_DefPool_New();
      if (PROTOBUF_G(global_symtab)) {
        zend_hash_init(&PROTOBUF_G(name_msg_cache), 64, NULL, NULL, 1);
        zend_hash_init(&PROTOBUF_G(name_enum_cache), 64, NULL, NULL, 1);
        idx = pool_cache_insert(key);
        if (idx >= 0) {
          PROTOBUF_G(pool_cache)[idx].symtab = PROTOBUF_G(global_symtab);
          PROTOBUF_G(pool_cache)[idx].name_msg_cache =
              PROTOBUF_G(name_msg_cache);
          PROTOBUF_G(pool_cache)[idx].name_enum_cache =
              PROTOBUF_G(name_enum_cache);
          PROTOBUF_G(active_pool_idx) = idx;
        }
        // else: couldn't register (OOM) -- active_pool_idx stays -1, so the
        // request runs on this pool as request-local and RSHUTDOWN frees it.
      } else {
        // Pool allocation failed: still initialize the name caches so
        // RSHUTDOWN's free path never destroys stale/uninitialized tables.
        zend_hash_init(&PROTOBUF_G(name_msg_cache), 64, NULL, NULL, 0);
        zend_hash_init(&PROTOBUF_G(name_enum_cache), 64, NULL, NULL, 0);
      }
    }
  } else {
    // Request-local mode (upstream default): fresh pool, freed in RSHUTDOWN.
    // descriptor_pool_key is ignored -- a keyed pool would have nothing to
    // persist into across requests.
    PROTOBUF_G(global_symtab) = upb_DefPool_New();
    zend_hash_init(&PROTOBUF_G(name_msg_cache), 64, NULL, NULL, 0);
    zend_hash_init(&PROTOBUF_G(name_enum_cache), 64, NULL, NULL, 0);
  }

  zend_hash_init(&PROTOBUF_G(object_cache), 64, NULL, NULL, 0);
  zend_hash_init(&PROTOBUF_G(descriptors), 64, NULL, ZVAL_PTR_DTOR, 0);
  PROTOBUF_G(constructing_class) = NULL;

  return SUCCESS;
}

/**
 * PHP_RSHUTDOWN_FUNCTION(protobuf)
 *
 * This function is run at the end of processing each request.
 */
static PHP_RSHUTDOWN_FUNCTION(protobuf) {
  // Consume the decision RINIT recorded. The INI settings are deliberately NOT
  // re-read here: ini_set() values are still in effect during RSHUTDOWN
  // (zend_ini_deactivate runs later), so re-reading them could free a pool
  // that pool_cache still references, or preserve request-local allocations.
  int idx = PROTOBUF_G(active_pool_idx);
  PROTOBUF_G(active_pool_idx) = -1;

  if (idx >= 0) {
    // Persistent pool: save the (possibly grown) state back to its cache entry
    // and detach the request globals WITHOUT freeing them -- the cache owns
    // these pools and frees them all in GSHUTDOWN at worker teardown. The
    // HashTables are stored by value, so growth during the request (realloc'd
    // arData, new counts) only exists in the globals' copy until saved back.
    if (PROTOBUF_G(global_symtab)) {
      PROTOBUF_G(pool_cache)[idx].symtab = PROTOBUF_G(global_symtab);
      PROTOBUF_G(pool_cache)[idx].name_msg_cache = PROTOBUF_G(name_msg_cache);
      PROTOBUF_G(pool_cache)[idx].name_enum_cache = PROTOBUF_G(name_enum_cache);
    }
    PROTOBUF_G(global_symtab) = NULL;
  } else {
    // Request-local pool: free it.
    free_protobuf_globals(ZEND_MODULE_GLOBALS_BULK(protobuf));
  }

  zend_hash_destroy(&PROTOBUF_G(object_cache));
  zend_hash_destroy(&PROTOBUF_G(descriptors));

  return SUCCESS;
}

// -----------------------------------------------------------------------------
// Object Cache.
// -----------------------------------------------------------------------------

void Descriptors_Add(zend_object* desc) {
  // The hash table will own a ref (it will destroy it when the table is
  // destroyed), but for some reason the insert operation does not add a ref, so
  // we do that here with ZVAL_OBJ_COPY().
  zval zv;
  ZVAL_OBJ_COPY(&zv, desc);
  zend_hash_next_index_insert(&PROTOBUF_G(descriptors), &zv);
}

void ObjCache_Add(const void* upb_obj, zend_object* php_obj) {
  zend_ulong k = (zend_ulong)upb_obj;
  zend_hash_index_add_ptr(&PROTOBUF_G(object_cache), k, php_obj);
}

void ObjCache_Delete(const void* upb_obj) {
  if (upb_obj) {
    zend_ulong k = (zend_ulong)upb_obj;
    int ret = zend_hash_index_del(&PROTOBUF_G(object_cache), k);
    PBPHP_ASSERT(ret == SUCCESS);
  }
}

bool ObjCache_Get(const void* upb_obj, zval* val) {
  zend_ulong k = (zend_ulong)upb_obj;
  zend_object* obj = zend_hash_index_find_ptr(&PROTOBUF_G(object_cache), k);

  if (obj) {
    ZVAL_OBJ_COPY(val, obj);
    return true;
  } else {
    ZVAL_NULL(val);
    return false;
  }
}

// -----------------------------------------------------------------------------
// Name Cache.
// -----------------------------------------------------------------------------

void NameMap_AddMessage(const upb_MessageDef* m) {
  for (int i = 0; i < 2; ++i) {
    char* k = GetPhpClassname(upb_MessageDef_File(m),
                              upb_MessageDef_FullName(m), (bool)i);
    zend_hash_str_add_ptr(&PROTOBUF_G(name_msg_cache), k, strlen(k), (void*)m);
    if (!IsPreviouslyUnreservedClassName(k)) {
      free(k);
      return;
    }
    free(k);
  }
}

void NameMap_AddEnum(const upb_EnumDef* e) {
  char* k =
      GetPhpClassname(upb_EnumDef_File(e), upb_EnumDef_FullName(e), false);
  zend_hash_str_add_ptr(&PROTOBUF_G(name_enum_cache), k, strlen(k), (void*)e);
  free(k);
}

const upb_MessageDef* NameMap_GetMessage(zend_class_entry* ce) {
  const upb_MessageDef* ret =
      zend_hash_find_ptr(&PROTOBUF_G(name_msg_cache), ce->name);

  if (!ret && ce->create_object && ce != PROTOBUF_G(constructing_class)) {
    zval zv;
    zend_object* tmp = ce->create_object(ce);
    zend_call_method_with_0_params(tmp, ce, NULL, "__construct", &zv);
    OBJ_RELEASE(tmp);
    zval_ptr_dtor(&zv);
    ret = zend_hash_find_ptr(&PROTOBUF_G(name_msg_cache), ce->name);
  }

  return ret;
}

const upb_EnumDef* NameMap_GetEnum(zend_class_entry* ce) {
  const upb_EnumDef* ret =
      zend_hash_find_ptr(&PROTOBUF_G(name_enum_cache), ce->name);
  return ret;
}

void NameMap_EnterConstructor(zend_class_entry* ce) {
  assert(!PROTOBUF_G(constructing_class));
  PROTOBUF_G(constructing_class) = ce;
}

void NameMap_ExitConstructor(zend_class_entry* ce) {
  assert(PROTOBUF_G(constructing_class) == ce);
  PROTOBUF_G(constructing_class) = NULL;
}

// -----------------------------------------------------------------------------
// Module init.
// -----------------------------------------------------------------------------

zend_function_entry protobuf_functions[] = {ZEND_FE_END};

static const zend_module_dep protobuf_deps[] = {ZEND_MOD_OPTIONAL("date")
                                                    ZEND_MOD_END};

PHP_INI_BEGIN()
STD_PHP_INI_ENTRY("protobuf.keep_descriptor_pool_after_request", "0",
                  PHP_INI_ALL, OnUpdateBool, keep_descriptor_pool_after_request,
                  zend_protobuf_globals, protobuf_globals)
STD_PHP_INI_ENTRY("protobuf.descriptor_pool_key", "",
                  PHP_INI_ALL, OnUpdateString, descriptor_pool_key,
                  zend_protobuf_globals, protobuf_globals)
PHP_INI_END()

static PHP_MINIT_FUNCTION(protobuf) {
  REGISTER_INI_ENTRIES();
  Arena_ModuleInit();
  Array_ModuleInit();
  Convert_ModuleInit();
  Def_ModuleInit();
  Map_ModuleInit();
  Message_ModuleInit();
  PrintOptions_ModuleInit();
  return SUCCESS;
}

static PHP_MSHUTDOWN_FUNCTION(protobuf) {
  UNREGISTER_INI_ENTRIES();
  return SUCCESS;
}

zend_module_entry protobuf_module_entry = {
    STANDARD_MODULE_HEADER_EX,
    NULL,
    protobuf_deps,
    "protobuf",                    // extension name
    protobuf_functions,            // function list
    PHP_MINIT(protobuf),           // process startup
    PHP_MSHUTDOWN(protobuf),       // process shutdown
    PHP_RINIT(protobuf),           // request startup
    PHP_RSHUTDOWN(protobuf),       // request shutdown
    NULL,                          // extension info
    PHP_PROTOBUF_VERSION,          // extension version
    PHP_MODULE_GLOBALS(protobuf),  // globals descriptor
    PHP_GINIT(protobuf),           // globals ctor
    PHP_GSHUTDOWN(protobuf),       // globals dtor
    NULL,                          // post deactivate
    STANDARD_MODULE_PROPERTIES_EX};

ZEND_GET_MODULE(protobuf)
