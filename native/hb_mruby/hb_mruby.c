/*
 * hb_mruby.c -- MRuby worker process for HyperBEAM Ruby device (Phase 2).
 *
 * Embeds MRuby and communicates with the BEAM via an Erlang port
 * using 4-byte length-prefixed Erlang External Term Format (ETF)
 * over stdio.
 *
 * Commands from Erlang (stdin):
 *   {init, #{modules => [Bin1, ...], host_ref => Ref}}
 *   {call, #{function => Fun, args => [Process, Message, Opts]}}
 *   {functions, #{}}
 *   {host_return, Ref, Result}   (response to host_call)
 *   {stop, #{}}
 *
 * Responses from worker (stdout):
 *   {ok, #{exports => [Atom1, ...]}}
 *   {result, #{status => ok, value => Result}}
 *   {error, #{class => Class, message => Message, trace => Trace}}
 *   {host_call, Ref, Function, Args}
 *   [functions] => [Atom1, ...]
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <inttypes.h>

#include "mruby.h"
#include "mruby/compile.h"
#include "mruby/variable.h"
#include "mruby/error.h"
#include "mruby/array.h"
#include "mruby/hash.h"
#include "mruby/class.h"
#include "mruby/string.h"

#include "ei.h"

#define ETF_BUF_SIZE 131072

/* - ETF I/O: 4-byte BE length prefix + magic byte + term bytes - */

static int etf_send_raw(const char *buf, int len)
{
    uint32_t netlen = htonl(1 + (uint32_t)len);
    if (fwrite(&netlen, sizeof(netlen), 1, stdout) != 1) return -1;
    unsigned char magic = 131;
    if (fwrite(&magic, 1, 1, stdout) != 1)             return -1;
    if (fwrite(buf, (size_t)len, 1, stdout) != 1)       return -1;
    return fflush(stdout) == EOF ? -1 : 0;
}

static int etf_send_x(ei_x_buff *x)
{
    int n = x->index;
    int r = etf_send_raw(x->buff, n);
    ei_x_free(x);
    return r;
}

/* - ETF -> MRuby - */

static mrb_value etf_to_mrb(mrb_state *mrb, const char *buf, int *idx);

static mrb_value etf_to_mrb(mrb_state *mrb, const char *buf, int *idx)
{
    int type, size;
    int idx_at_type = idx ? *idx : 0;  /* Position at the type byte */
    int idx_for_get_type = idx_at_type;  /* Copy for ei_get_type which advances it */
    if (ei_get_type(buf, &idx_for_get_type, &type, &size) < 0)
        return mrb_nil_value();
    /* idx_at_type still points AT type byte - used for all ei_decode_* calls */

    switch (type) {
    case ERL_SMALL_INTEGER_EXT: {
        long v; ei_decode_long(buf, &idx_at_type, &v);
        if (idx) *idx = idx_at_type;
        return mrb_int_value(mrb, (mrb_int)v);
    }
    case ERL_INTEGER_EXT: {
        long v; ei_decode_long(buf, &idx_at_type, &v);
        if (idx) *idx = idx_at_type;
        return mrb_int_value(mrb, (mrb_int)v);
    }
    case ERL_SMALL_BIG_EXT:
    case ERL_LARGE_BIG_EXT: {
        long v; ei_decode_long(buf, &idx_at_type, &v);
        if (idx) *idx = idx_at_type;
        return mrb_int_value(mrb, (mrb_int)v);
    }
    case ERL_ATOM_EXT:
    case ERL_SMALL_ATOM_EXT:
    case ERL_ATOM_UTF8_EXT:
    case ERL_SMALL_ATOM_UTF8_EXT: {
        char n[256];
        ei_decode_atom(buf, &idx_at_type, n);
        if (idx) *idx = idx_at_type;
        if      (strcmp(n, "true")  == 0) return mrb_true_value();
        else if (strcmp(n, "false") == 0) return mrb_false_value();
        else if (strcmp(n, "nil")   == 0) return mrb_nil_value();
        else if (strcmp(n, "null")  == 0) return mrb_nil_value();
        return mrb_symbol_value(mrb_intern_cstr(mrb, n));
    }
    case ERL_BINARY_EXT: {
        int idx_before = idx_at_type;
        long sl;
        ei_decode_binary(buf, &idx_at_type, (void *)0, &sl);
        if (sl <= 0 || sl > 1048576) { /* reject >1MB */
            fprintf(stderr, "hb_mruby: binary too large (%ld bytes)\n", sl);
            if (idx) *idx = idx_at_type;
            return mrb_nil_value();
        }
        char *b = malloc((size_t)sl);
        if (!b) {
            if (idx) *idx = idx_at_type;
            return mrb_nil_value();
        }
        /* Reset idx to re-decode the binary data */
        idx_at_type = idx_before;
        ei_decode_binary(buf, &idx_at_type, (void *)b, &sl);
        mrb_value s = mrb_str_new(mrb, b, (size_t)sl);
        free(b);
        if (idx) *idx = idx_at_type;
        return s;
    }
    case ERL_STRING_EXT: {
        /* ERL_STRING_EXT layout: 4-byte count (big-endian) + N bytes of data.
           ei_get_type already gave us the count in 'size'. */
        long sl = (long)size;
        if (sl <= 0 || sl > 1048576) { /* reject >1MB */
            fprintf(stderr, "hb_mruby: string too large (%ld bytes)\n", sl);
            /* Skip the 4-byte header + string data */
            idx_at_type += 4 + (int)sl;
            if (idx) *idx = idx_at_type;
            return mrb_nil_value();
        }
        char *s = malloc((size_t)sl + 1);
        if (!s) {
            idx_at_type += 4 + (int)sl;
            if (idx) *idx = idx_at_type;
            return mrb_nil_value();
        }
        /* Skip the 4-byte count header, then read from the ETF buffer */
        idx_at_type += 4;
        memcpy(s, buf + idx_at_type, (size_t)sl);
        idx_at_type += (int)sl;
        s[sl] = '\0';
        mrb_value str = mrb_str_new(mrb, s, (int)sl);
        free(s);
        if (idx) *idx = idx_at_type;
        return str;
    }
    case ERL_LIST_EXT: {
        int lene;
        ei_decode_list_header(buf, &idx_at_type, &lene);
        mrb_value arr = mrb_ary_new_capa(mrb, lene);
        while (lene-- > 0)
            mrb_ary_push(mrb, arr, etf_to_mrb(mrb, buf, &idx_at_type));
        /* Consume the ERL_NIL_EXT terminator */
        if (buf[idx_at_type] == (char)ERL_NIL_EXT)
            idx_at_type++;
        if (idx) *idx = idx_at_type;
        return arr;
    }
    case ERL_NIL_EXT:
        idx_at_type++;  /* consume the nil marker byte */
        if (idx) *idx = idx_at_type;
        return mrb_nil_value();
    case ERL_SMALL_TUPLE_EXT:
    case ERL_LARGE_TUPLE_EXT: {
        int arity;
        ei_decode_tuple_header(buf, &idx_at_type, &arity);
        if (arity == 2) {
            mrb_value a = etf_to_mrb(mrb, buf, &idx_at_type);
            mrb_value b = etf_to_mrb(mrb, buf, &idx_at_type);
            if (mrb_symbol_p(a)) {
                mrb_sym sk = mrb_symbol(a);
                const char *ks = mrb_sym2name(mrb, sk);
                mrb_value kstr = mrb_str_new_cstr(mrb, ks);
                mrb_value h = mrb_hash_new(mrb);
                mrb_hash_set(mrb, h, kstr, b);
                if (idx) *idx = idx_at_type;
                return h;
            }
            mrb_value arr = mrb_ary_new_capa(mrb, 2);
            mrb_ary_push(mrb, arr, a);
            mrb_ary_push(mrb, arr, b);
            if (idx) *idx = idx_at_type;
            return arr;
        }
        mrb_value arr = mrb_ary_new_capa(mrb, arity);
        for (int i = 0; i < arity; i++)
            mrb_ary_push(mrb, arr, etf_to_mrb(mrb, buf, &idx_at_type));
        if (idx) *idx = idx_at_type;
        return arr;
    }
    case ERL_MAP_EXT: {
        int arity;
        ei_decode_map_header(buf, &idx_at_type, &arity);
        mrb_value hsh = mrb_hash_new(mrb);
        for (int i = 0; i < arity; i++) {
            mrb_value k = etf_to_mrb(mrb, buf, &idx_at_type);
            mrb_value v = etf_to_mrb(mrb, buf, &idx_at_type);
            if (mrb_symbol_p(k)) {
                mrb_sym sym = mrb_symbol(k);
                const char *ns = mrb_sym2name(mrb, sym);
                int nl = (int)strlen(ns);
                k = mrb_str_new(mrb, ns, nl);
            }
            mrb_hash_set(mrb, hsh, k, v);
        }
        if (idx) *idx = idx_at_type;
        return hsh;
    }
    default:
        return mrb_nil_value();
    }
}

/* - MRuby -> ETF (via ei_x_buff) - */

static void mrb_to_eix(ei_x_buff *x, mrb_state *mrb, mrb_value val);

static void mrb_arr_to_eix(ei_x_buff *x, mrb_state *mrb, mrb_value arr)
{
    int len = RARRAY_LEN(arr);
    ei_x_encode_list_header(x, len);
    for (int i = 0; i < len; i++)
        mrb_to_eix(x, mrb, RARRAY_PTR(arr)[i]);
    ei_x_encode_empty_list(x);
}

static void mrb_hash_to_eix(ei_x_buff *x, mrb_state *mrb, mrb_value hsh)
{
    int len = mrb_hash_size(mrb, hsh);
    if (len < 0) len = 0;
    ei_x_encode_map_header(x, len);
    mrb_value keys = mrb_hash_keys(mrb, hsh);
    for (int i = 0; i < RARRAY_LEN(keys); i++) {
        mrb_value k = RARRAY_PTR(keys)[i];
        mrb_value v = mrb_hash_get(mrb, hsh, k);
        if (mrb_symbol_p(k)) {
            mrb_sym sym = mrb_symbol(k);
            const char *ns = mrb_sym2name(mrb, sym);
            int nl = (int)strlen(ns);
            k = mrb_str_new(mrb, ns, nl);
        }
        mrb_to_eix(x, mrb, k);
        mrb_to_eix(x, mrb, v);
    }
}

static void mrb_to_eix(ei_x_buff *x, mrb_state *mrb, mrb_value val)
{
    if (mrb_nil_p(val))     ei_x_encode_atom(x, "nil");
    else if (mrb_true_p(val))  ei_x_encode_atom(x, "true");
    else if (mrb_false_p(val)) ei_x_encode_atom(x, "false");
    else if (mrb_integer_p(val))
        ei_x_encode_longlong(x, (EI_LONGLONG)mrb_integer(val));
    else if (mrb_float_p(val))
        ei_x_encode_double(x, mrb_float(val));
    else if (mrb_symbol_p(val)) {
        const char *s = mrb_sym2name(mrb, mrb_symbol(val));
        ei_x_encode_atom(x, s);
    } else if (mrb_string_p(val)) {
        const char *s = mrb_string_cstr(mrb, val);
        ei_x_encode_binary(x, s, (int)RSTRING_LEN(val));
    } else if (mrb_array_p(val)) {
        mrb_arr_to_eix(x, mrb, val);
    } else if (mrb_hash_p(val)) {
        mrb_hash_to_eix(x, mrb, val);
    } else {
        ei_x_encode_atom(x, "unsupported_value");
    }
}

/* - Host call protocol - */

/* Global host call ref counter */
static int host_ref_counter = 0;

/*
 * Send a host_call to Erlang and block waiting for host_return.
 * Returns the result as an mrb_value.
 */
static mrb_value do_host_call(mrb_state *mrb, const char *func_name, mrb_value args)
{
    int ref = ++host_ref_counter;

    /* Emit {host_call, Ref, FunctionName, Args} */
    ei_x_buff x;
    ei_x_new(&x);
    ei_x_encode_tuple_header(&x, 4);
    ei_x_encode_atom(&x, "host_call");
    ei_x_encode_longlong(&x, (EI_LONGLONG)ref);
    ei_x_encode_atom(&x, func_name);
    mrb_to_eix(&x, mrb, args);
    etf_send_x(&x);

    /* Block waiting for {host_return, Ref, Result} */
    char buf[ETF_BUF_SIZE];
    while (1) {
        uint32_t netlen;
        if (fread(&netlen, sizeof(netlen), 1, stdin) != 1) break;
        int len = (int)ntohl(netlen);
        if (len <= 0 || len >= ETF_BUF_SIZE) break;
        if ((int)fread(buf, (size_t)len, 1, stdin) != 1) break;

        int idx = 1; /* skip magic */
        int type, size;
        if (ei_get_type(buf, &idx, &type, &size) < 0) continue;
        if (type != ERL_SMALL_TUPLE_EXT && type != ERL_LARGE_TUPLE_EXT) continue;

        int arity;
        ei_decode_tuple_header(buf, &idx, &arity);
        if (arity < 1) continue;

        char action[256];
        ei_decode_atom(buf, &idx, action);

        if (strcmp(action, "host_return") == 0 && arity >= 3) {
            long returned_ref;
            ei_decode_long(buf, &idx, &returned_ref);
            if (returned_ref == ref) {
                /* Decode result */
                mrb_value result = etf_to_mrb(mrb, buf, &idx);
                return result;
            }
            /* Not our ref - re-inject into stdin buffer? No, just skip.
               In practice refs are sequential so this shouldn't happen. */
        } else if (strcmp(action, "stop") == 0) {
            return mrb_nil_value();
        }
        /* Ignore other messages (shouldn't arrive during host call) */
    }
    return mrb_nil_value();
}

/* - AO module: Ruby host-call functions - */

/* AO.resolve(args) -> result */
static mrb_value ao_resolve(mrb_state *mrb, mrb_value self)
{
    mrb_value args;
    mrb_get_args(mrb, "o", &args);
    return do_host_call(mrb, "resolve", args);
}

/* AO.get(key, process) -> value */
static mrb_value ao_get(mrb_state *mrb, mrb_value self)
{
    mrb_value key, process;
    mrb_get_args(mrb, "oo", &key, &process);
    mrb_value args = mrb_ary_new_capa(mrb, 2);
    mrb_ary_push(mrb, args, key);
    mrb_ary_push(mrb, args, process);
    return do_host_call(mrb, "get", args);
}

/* AO.set(process, key, value) -> process */
static mrb_value ao_set(mrb_state *mrb, mrb_value self)
{
    mrb_value process, key, value;
    mrb_get_args(mrb, "ooo", &process, &key, &value);
    mrb_value args = mrb_ary_new_capa(mrb, 3);
    mrb_ary_push(mrb, args, process);
    mrb_ary_push(mrb, args, key);
    mrb_ary_push(mrb, args, value);
    return do_host_call(mrb, "set", args);
}

/* AO.event(category, data) -> result */
static mrb_value ao_event(mrb_state *mrb, mrb_value self)
{
    mrb_value category, data;
    mrb_get_args(mrb, "oo", &category, &data);
    mrb_value args = mrb_ary_new_capa(mrb, 2);
    mrb_ary_push(mrb, args, category);
    mrb_ary_push(mrb, args, data);
    return do_host_call(mrb, "event", args);
}

static void define_ao_module(mrb_state *mrb)
{
    struct RClass *ao = mrb_define_module(mrb, "AO");
    mrb_define_module_function(mrb, ao, "resolve", ao_resolve, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, ao, "get",     ao_get,     MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, ao, "set",     ao_set,     MRB_ARGS_REQ(3));
    mrb_define_module_function(mrb, ao, "event",   ao_event,   MRB_ARGS_REQ(2));
}

/* - Protect callback for mrb_protect_error - */

struct call_data {
    mrb_sym func;
    mrb_value ao_proc;
    mrb_value process;
    mrb_value message;
    mrb_value opts;
};

static mrb_value do_call(mrb_state *mrb, void *ud)
{
    struct call_data *cd = (struct call_data *)ud;
    return mrb_funcall_id(mrb, cd->ao_proc, cd->func, 3,
        cd->process, cd->message, cd->opts);
}

/* - Main event loop - */

int main(void)
{
    signal(SIGPIPE, SIG_IGN);

    mrb_state *mrb = mrb_open();
    if (!mrb) {
        fprintf(stderr, "hb_mruby: cannot open mrb_state\n");
        return 1;
    }
    define_ao_module(mrb);

    char buf[ETF_BUF_SIZE];
    while (1) {
        /* Read length-prefixed ETF term */
        uint32_t netlen;
        if (fread(&netlen, sizeof(netlen), 1, stdin) != 1) break;
        int len = (int)ntohl(netlen);
        if (len <= 0 || len >= ETF_BUF_SIZE) break;
        if ((int)fread(buf, (size_t)len, 1, stdin) != 1) break;

        if (len < 1) continue;
        int idx = 1;
        int type, size;
        int idx_at_type = idx;  /* Save position at type byte */
        if (ei_get_type(buf, &idx, &type, &size) < 0) continue;
        if (type != ERL_SMALL_TUPLE_EXT && type != ERL_LARGE_TUPLE_EXT) continue;
        int arity;
        ei_decode_tuple_header(buf, &idx_at_type, &arity);  /* Use idx_at_type */
        if (arity < 1) continue;

        char action[256];
        ei_decode_atom(buf, &idx_at_type, action);

        if (strcmp(action, "stop") == 0)
            break;

        /* - init - */
        if (strcmp(action, "init") == 0) {
            if (arity < 2) continue;
            mrb_value payload = etf_to_mrb(mrb, buf, &idx_at_type);
            mrb_value modules = mrb_nil_value();
            if (mrb_hash_p(payload)) {
                mrb_value k = mrb_str_new_cstr(mrb, "modules");
                modules = mrb_hash_get(mrb, payload, k);
            }
            if (!mrb_array_p(modules)) {
                if (!mrb_nil_p(modules)) {
                    ei_x_buff x; ei_x_new(&x);
                    ei_x_encode_tuple_header(&x, 1);
                    ei_x_encode_atom(&x, "init_error");
                    etf_send_x(&x);
                    continue;
                }
                modules = mrb_ary_new(mrb);
            }

            int ok = 1;
            for (int i = 0; i < RARRAY_LEN(modules); i++) {
                mrb_value src = RARRAY_PTR(modules)[i];
                if (!mrb_string_p(src)) continue;
                mrb_value res = mrb_load_string(mrb, mrb_string_cstr(mrb, src));
                if (mrb_obj_is_kind_of(mrb, res, mrb_class_get(mrb, "Exception"))) {
                    fprintf(stderr, "hb_mruby: module eval error\n");
                    ok = 0;
                    break;
                }
            }

            if (ok) {
                ei_x_buff x;
                ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 2);
                ei_x_encode_atom(&x, "ok");
                ei_x_encode_map_header(&x, 1);
                ei_x_encode_atom(&x, "exports");

                mrb_value ao_proc = mrb_nil_value();
                if (mrb_const_defined(mrb, mrb_obj_value(mrb->object_class),
                                      mrb_intern_cstr(mrb, "AOProcess"))) {
                    ao_proc = mrb_const_get(mrb, mrb_obj_value(mrb->object_class),
                                              mrb_intern_cstr(mrb, "AOProcess"));
                }
                if (!mrb_nil_p(ao_proc)) {
                    mrb_value ms = mrb_funcall(mrb, ao_proc, "singleton_methods", 1, mrb_false_value());
                    if (mrb_array_p(ms)) {
                        int ml = RARRAY_LEN(ms);
                        ei_x_encode_list_header(&x, ml);
                        for (int i = 0; i < ml; i++) {
                            mrb_value m = RARRAY_PTR(ms)[i];
                            const char *s = NULL;
                            if (mrb_symbol_p(m))
                                s = mrb_sym2name(mrb, mrb_symbol(m));
                            else if (mrb_string_p(m))
                                s = mrb_string_cstr(mrb, m);
                            if (s) ei_x_encode_atom(&x, s);
                        }
                        ei_x_encode_empty_list(&x);
                    } else {
                        ei_x_encode_list_header(&x, 0);
                        ei_x_encode_empty_list(&x);
                    }
                } else {
                    ei_x_encode_list_header(&x, 0);
                    ei_x_encode_empty_list(&x);
                }
                etf_send_x(&x);
            } else {
                ei_x_buff x; ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 1);
                ei_x_encode_atom(&x, "init_error");
                etf_send_x(&x);
            }
        }

        /* - call - */
        if (strcmp(action, "call") == 0) {
            if (arity < 2) continue;
            mrb_value payload = etf_to_mrb(mrb, buf, &idx_at_type);
            mrb_value fun_val = mrb_nil_value();
            mrb_value args_val = mrb_nil_value();
            if (mrb_hash_p(payload)) {
                fun_val  = mrb_hash_get(mrb, payload, mrb_str_new_cstr(mrb, "function"));
                args_val = mrb_hash_get(mrb, payload, mrb_str_new_cstr(mrb, "args"));
            }

            const char *fn = NULL;
            if (mrb_symbol_p(fun_val))
                fn = mrb_sym2name(mrb, mrb_symbol(fun_val));
            else if (mrb_string_p(fun_val))
                fn = mrb_string_cstr(mrb, fun_val);

            if (!fn) {
                ei_x_buff x; ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 2);
                ei_x_encode_atom(&x, "error");
                ei_x_encode_map_header(&x, 2);
                ei_x_encode_atom(&x, "class");
                ei_x_encode_binary(&x, "Error", 5);
                ei_x_encode_atom(&x, "message");
                ei_x_encode_binary(&x, "No function name", 16);
                etf_send_x(&x);
                continue;
            }

            mrb_sym fs = mrb_intern_cstr(mrb, fn);
            mrb_value ao_proc = mrb_nil_value();
            if (!mrb_const_defined(mrb, mrb_obj_value(mrb->object_class),
                                    mrb_intern_cstr(mrb, "AOProcess"))) {
                ei_x_buff x; ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 2);
                ei_x_encode_atom(&x, "error");
                ei_x_encode_map_header(&x, 2);
                ei_x_encode_atom(&x, "class");
                ei_x_encode_binary(&x, "NameError", 9);
                ei_x_encode_atom(&x, "message");
                ei_x_encode_binary(&x, "AOProcess not defined", 21);
                etf_send_x(&x);
                continue;
            }
            ao_proc = mrb_const_get(mrb, mrb_obj_value(mrb->object_class),
                                      mrb_intern_cstr(mrb, "AOProcess"));

            /* Extract [process, message, opts] from args array */
            mrb_value process = mrb_nil_value();
            mrb_value message = mrb_nil_value();
            mrb_value opts    = mrb_nil_value();
            if (mrb_array_p(args_val)) {
                int alen = RARRAY_LEN(args_val);
                if (alen >= 1) process = RARRAY_PTR(args_val)[0];
                if (alen >= 2) message = RARRAY_PTR(args_val)[1];
                if (alen >= 3) opts    = RARRAY_PTR(args_val)[2];
                /* Ensure hashes */
                if (!mrb_hash_p(process)) process = mrb_hash_new(mrb);
                if (!mrb_hash_p(message)) message = mrb_hash_new(mrb);
                if (!mrb_hash_p(opts))    opts    = mrb_hash_new(mrb);
            }

            struct call_data cd;
            cd.func    = fs;
            cd.ao_proc = ao_proc;
            cd.process = process;
            cd.message = message;
            cd.opts    = opts;

            mrb_bool error = 0;
            mrb_value result = mrb_protect_error(mrb, do_call, &cd, &error);

            if (error != 0) {
                struct RObject *exc = mrb->exc;
                mrb_value msg_val = mrb_funcall(mrb, mrb_obj_value(exc), "message", 0);
                const char *ms = NULL;
                if (mrb_string_p(msg_val))
                    ms = mrb_string_cstr(mrb, msg_val);
                if (!ms) ms = "unknown error";

                struct RClass *ec = mrb_obj_class(mrb, mrb_obj_value(exc));
                const char *cn = mrb_class_name(mrb, ec);
                if (!cn) cn = "Exception";

                ei_x_buff x; ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 2);
                ei_x_encode_atom(&x, "error");
                ei_x_encode_map_header(&x, 3);
                ei_x_encode_atom(&x, "class");
                ei_x_encode_binary(&x, cn, (int)strlen(cn));
                ei_x_encode_atom(&x, "message");
                ei_x_encode_binary(&x, ms, (int)strlen(ms));
                ei_x_encode_atom(&x, "trace");
                ei_x_encode_binary(&x, "", 0);
                etf_send_x(&x);
                mrb->exc = NULL;
            } else {
                ei_x_buff x; ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 2);
                ei_x_encode_atom(&x, "result");
                ei_x_encode_map_header(&x, 2);
                ei_x_encode_atom(&x, "status");
                ei_x_encode_atom(&x, "ok");
                ei_x_encode_atom(&x, "value");
                mrb_to_eix(&x, mrb, result);
                etf_send_x(&x);
            }
        }

        /* - functions - */
        if (strcmp(action, "functions") == 0) {
            mrb_value ao_proc = mrb_nil_value();
            if (mrb_const_defined(mrb, mrb_obj_value(mrb->object_class),
                                    mrb_intern_cstr(mrb, "AOProcess"))) {
                ao_proc = mrb_const_get(mrb, mrb_obj_value(mrb->object_class),
                                          mrb_intern_cstr(mrb, "AOProcess"));
            }
            if (mrb_nil_p(ao_proc)) {
                ei_x_buff x; ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 2);
                ei_x_encode_atom(&x, "functions");
                ei_x_encode_list_header(&x, 0);
                ei_x_encode_empty_list(&x);
                etf_send_x(&x);
                continue;
            }
            mrb_value ms = mrb_funcall(mrb, ao_proc, "singleton_methods", 1, mrb_false_value());
            if (mrb_array_p(ms)) {
                int ml = RARRAY_LEN(ms);
                ei_x_buff x; ei_x_new(&x);
                ei_x_encode_tuple_header(&x, 2);
                ei_x_encode_atom(&x, "functions");
                ei_x_encode_list_header(&x, ml);
                for (int i = 0; i < ml; i++) {
                    mrb_value m = RARRAY_PTR(ms)[i];
                    const char *s = NULL;
                    if (mrb_symbol_p(m))
                        s = mrb_sym2name(mrb, mrb_symbol(m));
                    else if (mrb_string_p(m))
                        s = mrb_string_cstr(mrb, m);
                    if (s) ei_x_encode_atom(&x, s);
                }
                ei_x_encode_empty_list(&x);
                etf_send_x(&x);
            }
        }
    }

    mrb_close(mrb);
    return 0;
}
