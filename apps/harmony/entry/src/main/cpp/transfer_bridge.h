#ifndef XDREMUX_HARMONY_TRANSFER_BRIDGE_H
#define XDREMUX_HARMONY_TRANSFER_BRIDGE_H

#include "napi/native_api.h"

namespace xdremux_transfer_napi {

napi_value abi_version(napi_env env, napi_callback_info info);
napi_value create(napi_env env, napi_callback_info info);
napi_value submit(napi_env env, napi_callback_info info);
napi_value poll(napi_env env, napi_callback_info info);
napi_value stop(napi_env env, napi_callback_info info);
napi_value release(napi_env env, napi_callback_info info);

} // namespace xdremux_transfer_napi

#endif
