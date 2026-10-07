#include <napi/native_api.h>
#include <pthread.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

extern "C" {
#include "States.h"
#include "NetClient.h"
#include "cipher/CipherInterface.h"
#include "utils/PlatformUtils.h"
int oh_authenticate(void);
int oh_send_heartbeat(void);
int oh_disconnect(void);
}

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static prog_status_t account = {};
static bool requested = false;
static char phase[32] = "idle";
static char detail[160] = "等待连接";
static char lines[24][192] = {};
static size_t line_count = 0;

static void record(const char* message)
{
    time_t now = time(nullptr);
    struct tm local = {};
    localtime_r(&now, &local);
    if (line_count == 24) {
        memmove(lines, lines + 1, sizeof(lines) - sizeof(lines[0]));
        line_count--;
    }
    snprintf(lines[line_count++], sizeof(lines[0]), "%02d:%02d:%02d  %s",
        local.tm_hour, local.tm_min, local.tm_sec, message);
}

static void set_phase(const char* name, const char* message)
{
    snprintf(phase, sizeof(phase), "%s", name);
    snprintf(detail, sizeof(detail), "%s", message);
    record(message);
}

static void clear_auth()
{
    account.runtime_status.is_authed = false;
    account.runtime_status.is_initialized = false;
    account.auth_cfg.auth_time = 0;
}

static void run_start(const char* user, const char* pass)
{
    if (!user[0] || !pass[0]) { set_phase("error", "请先填写账号和密码"); return; }
    if (strlen(user) >= USR_LEN || strlen(pass) >= PWD_LEN) {
        set_phase("error", "账号或密码超过协议长度限制"); return;
    }
    struct PasswordClear {
        ~PasswordClear() { memset(account.login_cfg.pwd, 0, sizeof(account.login_cfg.pwd)); }
    } passwordClear;
    requested = true;
    if (account.runtime_status.is_authed) oh_disconnect();
    destroy_cipher_factory();
    clear_auth();
    memset(account.last_location, 0, sizeof(account.last_location));
    account.last_location_lock = false;
    memset(&account.auth_cfg, 0, sizeof(account.auth_cfg));
    snprintf(account.login_cfg.usr, USR_LEN, "%s", user);
    snprintf(account.login_cfg.pwd, PWD_LEN, "%s", pass);
    account.login_cfg.chn = 3;
    account.login_cfg.idx = 1;
    snprintf(account.login_cfg.user_agent, USER_AGENT_LEN, "CCTP/android11_64/2104");
    set_phase("connecting", "正在检测校园网络");
    refresh_states();
    network_status_t net = check_network_status(false);
    if (net == STATUS_OK) { set_phase("online", "网络已连通"); return; }
    if (net != STATUS_NEED_AUTH || !account.last_location[0]) {
        set_phase("error", "未检测到可用的校园认证入口"); return;
    }
    for (int i = 0; i < 5; i++) {
        char previous[LAST_LOCATION_LEN * 2];
        snprintf(previous, sizeof(previous), "%s", account.last_location);
        curl_resp_t response = get(previous, false);
        long code = response.http_code;
        free(response.body_data);
        if (code == 200) break;
        if (code != 302 || !strcmp(previous, account.last_location)) {
            set_phase("error", "无法读取校园认证页面"); return;
        }
    }
    set_phase("connecting", "正在获取票据并验证账号");
    if (oh_authenticate() == 0) set_phase("connected", "校园网认证成功");
    else { clear_auth(); set_phase("error", "认证失败，请检查账号或网络"); }
}

static void run_pulse()
{
    if (!requested) return;
    network_status_t net = check_network_status(false);
    if (net == STATUS_NEED_AUTH) {
        if (account.runtime_status.is_authed) {
            clear_auth();
            destroy_cipher_factory();
            set_phase("error", "连接已中断，请重新连接");
        } else set_phase("error", "网络仍需认证，请重新连接");
        return;
    }
    if (net == STATUS_ERROR) {
        if (account.runtime_status.is_authed) {
            clear_auth();
            destroy_cipher_factory();
        }
        set_phase("error", "网络不可用，请检查 Wi-Fi");
        return;
    }
    if (account.runtime_status.is_authed) {
        uint64_t due = account.auth_cfg.keep_retry * 1000;
        if (due && get_cur_tm_ms() - account.auth_cfg.tick >= due) {
            if (oh_send_heartbeat() == 0) {
                account.auth_cfg.tick = get_cur_tm_ms();
                record("心跳验证成功");
            } else {
                clear_auth();
                destroy_cipher_factory();
                set_phase("error", "心跳验证失败，请重新连接");
            }
        }
    } else if (strcmp(phase, "online")) set_phase("online", "网络已连通");
}

static void run_stop()
{
    requested = false;
    if (account.runtime_status.is_authed && oh_disconnect() != 0)
        record("登出请求未获确认");
    destroy_cipher_factory();
    clear_auth();
    memset(account.login_cfg.pwd, 0, sizeof(account.login_cfg.pwd));
    set_phase("idle", "已断开连接");
}

struct Work {
    napi_env env;
    napi_async_work work;
    napi_deferred deferred;
    int operation;
    char user[USR_LEN];
    char pass[PWD_LEN];
};

static napi_value make_status(napi_env env)
{
    napi_value object, value;
    napi_create_object(env, &object);
    napi_create_string_utf8(env, phase, NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, object, "phase", value);
    napi_create_string_utf8(env, detail, NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, object, "detail", value);
    napi_get_boolean(env, account.runtime_status.is_authed, &value);
    napi_set_named_property(env, object, "authenticated", value);
    napi_get_boolean(env, requested, &value);
    napi_set_named_property(env, object, "running", value);
    napi_create_int64(env, (int64_t)account.auth_cfg.auth_time, &value);
    napi_set_named_property(env, object, "connectedAt", value);
    napi_create_array_with_length(env, line_count, &value);
    for (size_t i=0; i<line_count; i++) {
        napi_value line; napi_create_string_utf8(env, lines[i], NAPI_AUTO_LENGTH, &line);
        napi_set_element(env, value, i, line);
    }
    napi_set_named_property(env, object, "logs", value);
    return object;
}

static void execute(napi_env env, void* data)
{
    (void)env;
    Work* task = static_cast<Work*>(data);
    pthread_mutex_lock(&mutex);
    tl_thread_idx = 0;
    if (task->operation == 1) run_start(task->user, task->pass);
    else if (task->operation == 2) run_pulse();
    else if (task->operation == 3) run_stop();
    pthread_mutex_unlock(&mutex);
}

static void complete(napi_env env, napi_status status, void* data)
{
    Work* task = static_cast<Work*>(data);
    pthread_mutex_lock(&mutex);
    napi_value result = make_status(env);
    pthread_mutex_unlock(&mutex);
    if (status == napi_ok) napi_resolve_deferred(env, task->deferred, result);
    else napi_reject_deferred(env, task->deferred, result);
    napi_delete_async_work(env, task->work);
    memset(task->pass, 0, sizeof(task->pass));
    delete task;
}

static napi_value schedule(napi_env env, napi_callback_info info, int operation)
{
    size_t count = operation == 1 ? 2 : 0;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    Work* task = new Work{};
    task->env=env; task->operation=operation;
    if (operation == 1) {
        if (count != 2 || !args[0] || !args[1]) { delete task; napi_throw_type_error(env,nullptr,"账号和密码不能为空"); return nullptr; }
        size_t userLength=0, passLength=0;
        if (napi_get_value_string_utf8(env,args[0],nullptr,0,&userLength)!=napi_ok ||
            napi_get_value_string_utf8(env,args[1],nullptr,0,&passLength)!=napi_ok) {
            delete task; napi_throw_type_error(env,nullptr,"账号和密码必须是文本"); return nullptr;
        }
        if (userLength>=sizeof(task->user) || passLength>=sizeof(task->pass)) {
            delete task; napi_throw_range_error(env,nullptr,"账号或密码过长"); return nullptr;
        }
        napi_get_value_string_utf8(env,args[0],task->user,sizeof(task->user),&userLength);
        napi_get_value_string_utf8(env,args[1],task->pass,sizeof(task->pass),&passLength);
    }
    napi_value promise, name;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_string_utf8(env, "ohsurfing-auth", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, execute, complete, task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

static napi_value start(napi_env e,napi_callback_info i) { return schedule(e,i,1); }
static napi_value pulse(napi_env e,napi_callback_info i) { return schedule(e,i,2); }
static napi_value stop(napi_env e,napi_callback_info i) { return schedule(e,i,3); }
static napi_value status(napi_env e,napi_callback_info i)
{
    (void)i; pthread_mutex_lock(&mutex); napi_value value=make_status(e); pthread_mutex_unlock(&mutex); return value;
}

static napi_value init(napi_env env, napi_value exports)
{
    g_prog_status = &account;
    g_prog_cnt = 1;
    g_thread_keep_alive = true;
    napi_property_descriptor methods[] = {
        {"start",nullptr,start,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"pulse",nullptr,pulse,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"stop",nullptr,stop,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"status",nullptr,status,nullptr,nullptr,nullptr,napi_default,nullptr}
    };
    napi_define_properties(env,exports,4,methods);
    return exports;
}

static napi_module module = {1,0,nullptr,init,"ohsurfing",nullptr,{0}};
extern "C" __attribute__((constructor)) void register_module(void) { napi_module_register(&module); }
