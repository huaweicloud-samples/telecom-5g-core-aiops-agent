# =============================================================================
# AIOps 智能体 — FunctionGraph handler
# -----------------------------------------------------------------------------
# 本函数用 FunctionGraph（Python3.9）+ 盘古大模型（ModelArts MaaS OpenAI 兼容
# 端点）实现跨层运维智能体：通过工具调用查询 CCE（K8s）/ VPC 安全组 /
# CTS 审计 / CES 告警，实现「Pod 日志 → 安全组 → 审计日志」的跨层根因定位。
#
# 关键工程约束：
#  1. handler 入口先 print("=== HANDLER ENTRY ===")，避免「日志全空」静默死锁。
#  2. 所有华为云 SDK 的 import 与客户端构建都放在函数内部（懒加载），
#     即使打包缺依赖，错误也会打印出来而非静默崩溃。
#  3. 华为云委托临时凭证只经 context 注入，不进任何环境变量。
#  4. obs / cryptography 原生模块华为云 FGS 已内置，切勿自带（否则日志全空）。
# =============================================================================

import json
import os
import base64
import ssl
import urllib.request
import logging

logger = logging.getLogger()
logging.basicConfig(level=logging.INFO)

MAX_ITER = 6  # 工具调用循环上限，避免无限循环

SYSTEM_PROMPT = """你是一名 SRE AIOps 助手，负责排查运行在华为云 CCE（Kubernetes）上的
5G 核心网 demo。5G 核心网由若干网络功能（NRF/AMF/SMF/UPF/PCF）组成，它们把注册
信息写入 DCS Redis，NRF 依赖 Redis 做服务发现。

你可以通过工具跨层关联以下信号来定位根因：
- CCE/K8s：Pod 状态与日志、节点状态（kube_* 工具，最可靠）
- VPC 安全组：Redis 6379 的入方向规则是否被改动（vpc_* 工具）
- CTS 审计：最近谁、什么时间改了安全组或集群资源（cts_* 工具）
- CES 告警：哪些 5G-Core-* 告警正处于告警态（ces_* 工具）

工作原则：
1. 先收集证据（调用工具），再下结论；不要臆测。
2. 针对「谁改了什么」这类问题，优先查 CTS 审计与 VPC 安全组规则。
3. 回答用中文，结构化（根因 / 证据 / 建议处置），控制在 300 字以内。
4. 如果工具返回为空或报错，说明该层无法取证，并尝试其他层。
"""


# ============================================================================
# 工具定义（model_adapter 转换为 OpenAI tools 格式）
# ============================================================================

TOOL_CONFIG = {
    "tools": [
        {
            "toolSpec": {
                "name": "kube_get_pods",
                "description": "列出指定命名空间下的 Pod 及其状态（相位/重启次数/所在节点/最近不可用原因）。用于判断哪些 NF 异常。",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {
                            "namespace": {"type": "string", "description": "命名空间，默认 demo-5g"}
                        },
                        "required": []
                    }
                }
            }
        },
        {
            "toolSpec": {
                "name": "kube_get_pod_logs",
                "description": "获取某个 Pod 的最近日志（tailLines 行）。用于从 NF 日志里找 Redis 断连、注册失败等线索。",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {
                            "namespace": {"type": "string"},
                            "pod": {"type": "string", "description": "Pod 名称"},
                            "tailLines": {"type": "integer", "description": "默认 50"}
                        },
                        "required": ["pod"]
                    }
                }
            }
        },
        {
            "toolSpec": {
                "name": "kube_get_nodes",
                "description": "列出集群节点及其 Ready 状态、CPU 压力。用于判断节点资源是否饱和（扩不出节点/Pod 调度失败）。",
                "inputSchema": {"json": {"type": "object", "properties": {}, "required": []}}
            }
        },
        {
            "toolSpec": {
                "name": "vpc_list_secgroup_rules",
                "description": "列出某个安全组的所有规则（方向/协议/端口/来源）。用于确认 Redis 6379 入方向是否还放行 Pod 网段。",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {
                            "security_group_id": {"type": "string"}
                        },
                        "required": ["security_group_id"]
                    }
                }
            }
        },
        {
            "toolSpec": {
                "name": "cts_find_sg_changes",
                "description": "查询 CTS 审计，找出最近对安全组或集群资源的增删改操作（谁、什么时间、改了什么）。用于回答「谁动了安全组」这类问题。",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {
                            "minutes": {"type": "integer", "description": "回溯时间窗（分钟），默认 60"}
                        },
                        "required": []
                    }
                }
            }
        },
        {
            "toolSpec": {
                "name": "ces_list_alarms",
                "description": "列出 CES 告警规则及其当前状态，筛选 5G-Core-* 告警。用于确认哪些告警处于告警态。",
                "inputSchema": {"json": {"type": "object", "properties": {}, "required": []}}
            }
        },
    ]
}

TOOLS = {}  # name -> (func, needs_context)


# ============================================================================
# K8s API 客户端（纯 urllib，无需 SDK）
# ============================================================================

def _kube_request(path):
    apiserver = os.environ.get("KUBE_APISERVER", "")
    token = os.environ.get("KUBE_TOKEN", "")
    ca_b64 = os.environ.get("KUBE_CA_B64", "")
    if not apiserver or not token:
        raise RuntimeError("缺少 KUBE_APISERVER / KUBE_TOKEN 环境变量（由 deploy.sh 写入 agent.auto.tfvars）")

    ctx = ssl.create_default_context()
    if ca_b64:
        ca_pem = base64.b64decode(ca_b64).decode("utf-8", "ignore")
        try:
            ctx = ssl.create_default_context(cadata=ca_pem)
        except Exception:
            import tempfile, os as _os
            fd, p = tempfile.mkstemp(suffix=".pem")
            with _os.fdopen(fd, "w") as f:
                f.write(ca_pem)
            ctx = ssl.create_default_context(cafile=p)

    req = urllib.request.Request(apiserver.rstrip("/") + path)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
            raw = resp.read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        # 非 2xx：返回错误码 + 简要内容，让工具/模型能看到真实报错而非崩溃
        detail = e.read().decode("utf-8", "ignore")[:500]
        return {"error": f"HTTP {e.code}", "detail": detail}
    except urllib.error.URLError as e:
        return {"error": "URLError", "detail": str(e)[:300]}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # 某些接口（如 /log）返回纯文本，返回截断文本供模型分析
        return {"text": raw[:4000]}


def _tool_kube_get_pods(inp, context):
    ns = inp.get("namespace", "demo-5g")
    data = _kube_request(f"/api/v1/namespaces/{ns}/pods")
    rows = []
    for item in data.get("items", []):
        md = item.get("metadata", {})
        st = item.get("status", {})
        cs = st.get("containerStatuses", [{}])
        restarts = sum(c.get("restartCount", 0) for c in cs)
        reason = st.get("reason") or (cs[0].get("state", {}).get("waiting", {}).get("reason", ""))
        rows.append({
            "name": md.get("name"),
            "phase": st.get("phase"),
            "node": md.get("spec", {}).get("nodeName"),
            "restarts": restarts,
            "not_ready_reason": reason,
        })
    return json.dumps({"namespace": ns, "count": len(rows), "pods": rows}, ensure_ascii=False)


def _tool_kube_get_pod_logs(inp, context):
    ns = inp.get("namespace", "demo-5g")
    pod = inp.get("pod", "")
    tail = int(inp.get("tailLines", 50))
    data = _kube_request(f"/api/v1/namespaces/{ns}/pods/{pod}/log?tailLines={tail}")
    # 容错：纯文本日志 / HTTP 错误 / 普通 dict
    if isinstance(data, dict) and "error" in data:
        return json.dumps({"pod": pod, "error": data.get("error"), "detail": data.get("detail", "")}, ensure_ascii=False)
    if isinstance(data, dict) and "text" in data:
        return json.dumps({"pod": pod, "log": data["text"]}, ensure_ascii=False)
    if isinstance(data, str):
        return json.dumps({"pod": pod, "log": data}, ensure_ascii=False)
    return json.dumps({"pod": pod, "log": str(data)}, ensure_ascii=False)


def _tool_kube_get_nodes(inp, context):
    data = _kube_request("/api/v1/nodes")
    rows = []
    for item in data.get("items", []):
        md = item.get("metadata", {})
        st = item.get("status", {})
        cond = {c.get("type"): c.get("status") for c in st.get("conditions", [])}
        rows.append({
            "name": md.get("name"),
            "ready": cond.get("Ready"),
            "memoryPressure": cond.get("MemoryPressure"),
            "diskPressure": cond.get("DiskPressure"),
        })
    return json.dumps({"count": len(rows), "nodes": rows}, ensure_ascii=False)


# ============================================================================
# 华为云 SDK 客户端构建（懒加载；委托临时凭证来自 context）
# ============================================================================

def _hw_credentials(context):
    from huaweicloudsdkcore.auth.credentials import BasicCredentials
    ak = sk = token = None
    if context is not None:
        try:
            ak = context.getSecurityAccessKey()
            sk = context.getSecuritySecretKey()
            token = context.getSecurityToken()
        except Exception:
            pass
    if not ak or not sk:
        raise RuntimeError("未拿到 FunctionGraph 委托临时凭证，请确认函数已绑定 agent agency")
    return BasicCredentials(ak, sk, os.environ.get("HW_PROJECT_ID")).with_security_token(token)


def _tool_vpc_list_secgroup_rules(inp, context):
    from huaweicloudsdkvpc.v2 import VpcClient
    from huaweicloudsdkvpc.v2.region.vpc_region import VpcRegion
    from huaweicloudsdkvpc.v2 import ListSecurityGroupRulesRequest

    sg_id = inp.get("security_group_id", "")
    if not sg_id:
        return json.dumps({"error": "security_group_id 必填"})
    creds = _hw_credentials(context)
    client = VpcClient.new_builder() \
        .with_credentials(creds) \
        .with_region(VpcRegion.value_of(os.environ.get("REGION", "cn-north-4"))) \
        .build()
    req = ListSecurityGroupRulesRequest(security_group_id=sg_id)
    resp = client.list_security_group_rules(req)
    rules = []
    for r in (resp.security_group_rules or []):
        rules.append({
            "id": getattr(r, "id", None),
            "direction": getattr(r, "direction", None),
            "protocol": getattr(r, "protocol", None),
            "port_range": f"{getattr(r,'port_range_min',None)}-{getattr(r,'port_range_max',None)}",
            "remote": getattr(r, "remote_ip_prefix", None) or getattr(r, "remote_group_id", None),
        })
    return json.dumps({"security_group_id": sg_id, "rules": rules}, ensure_ascii=False)


def _tool_cts_find_sg_changes(inp, context):
    from huaweicloudsdkcts.v3 import CtsClient
    from huaweicloudsdkcts.v3.region.cts_region import CtsRegion
    from huaweicloudsdkcts.v3 import ListTracesRequest

    minutes = int(inp.get("minutes", 60))
    now_ms = __import__("time").time() * 1000
    from_ms = now_ms - minutes * 60 * 1000
    creds = _hw_credentials(context)
    client = CtsClient.new_builder() \
        .with_credentials(creds) \
        .with_region(CtsRegion.value_of(os.environ.get("REGION", "cn-north-4"))) \
        .build()
    req = ListTracesRequest(
        tracker_name="system",
        limit=50,
        from_=int(from_ms),
        to=int(now_ms),
    )
    resp = client.list_traces(req)
    traces = []
    for t in (getattr(resp, "traces", None) or []):
        name = getattr(t, "trace_name", "") or ""
        if "ecurity" in name or "ecurityGroup" in name or "Vpc" in name:
            traces.append({
                "time": getattr(t, "time", None),
                "user": getattr(t, "user", {}).get("name") if isinstance(getattr(t, "user", None), dict) else getattr(t, "user", None),
                "trace_name": name,
                "resource": getattr(t, "resource_name", None),
                "status": getattr(t, "response_code", None),
            })
    return json.dumps({"window_minutes": minutes, "matched": traces}, ensure_ascii=False)


def _tool_ces_list_alarms(inp, context):
    from huaweicloudsdkces.v1 import CesClient
    from huaweicloudsdkces.v1.region.ces_region import CesRegion
    from huaweicloudsdkces.v1 import ListAlarmsRequest

    creds = _hw_credentials(context)
    client = CesClient.new_builder() \
        .with_credentials(creds) \
        .with_region(CesRegion.value_of(os.environ.get("REGION", "cn-north-4"))) \
        .build()
    req = ListAlarmsRequest()
    resp = client.list_alarms(req)
    alarms = []
    for a in (getattr(resp, "alarms", None) or []):
        name = getattr(a, "alarm_name", "") or ""
        if name.startswith("5G-Core"):
            alarms.append({
                "name": name,
                "state": getattr(a, "alarm_state", None),
                "level": getattr(a, "alarm_level", None),
            })
    return json.dumps({"alarms": alarms}, ensure_ascii=False)


TOOLS = {
    "kube_get_pods": (_tool_kube_get_pods, False),
    "kube_get_pod_logs": (_tool_kube_get_pod_logs, False),
    "kube_get_nodes": (_tool_kube_get_nodes, False),
    "vpc_list_secgroup_rules": (_tool_vpc_list_secgroup_rules, True),
    "cts_find_sg_changes": (_tool_cts_find_sg_changes, True),
    "ces_list_alarms": (_tool_ces_list_alarms, True),
}


# ============================================================================
# 智能体循环
# ============================================================================

def _dispatch(name, inp, context):
    entry = TOOLS.get(name)
    if not entry:
        return json.dumps({"error": f"unknown tool {name}"})
    func, needs_ctx = entry
    try:
        return func(inp, context if needs_ctx else None)
    except Exception as e:
        logger.exception("tool %s failed", name)
        return json.dumps({"error": f"{name} 执行失败: {e}"}, ensure_ascii=False)


def investigate(prompt, context):
    from model_adapter import create_model_client

    # 华为云 MaaS OpenAI 兼容统一入口（贵阳一/贵阳二预置服务均走此端点）
    # base_url/model 直接写死，避免依赖 user_data 更新（FSS.0403 限权时无法改配置）
    model = create_model_client(
        provider="huaweicloud",
        region=os.environ.get("REGION", "cn-north-4"),
        base_url="https://api.modelarts-maas.com/v2",
        api_key=os.environ.get("MAAS_API_KEY", ""),
    )
    model_id = "openpangu-2.0-flash"

    messages = [{"role": "user", "content": [{"text": prompt}]}]

    for step in range(MAX_ITER):
        resp = model.converse(
            messages=messages,
            model_id=model_id,
            system=SYSTEM_PROMPT,
            tool_config=TOOL_CONFIG,
            inference_config={"maxTokens": 1500, "temperature": 0.2},
        )
        assistant_msg = resp.output["message"]
        messages.append(assistant_msg)

        content = assistant_msg.get("content", [])
        tool_uses = [b for b in content if "toolUse" in b]
        if not tool_uses:
            text = "".join(b.get("text", "") for b in content if "text" in b)
            return text

        for tu in tool_uses:
            name = tu["toolUse"]["name"]
            tid = tu["toolUse"]["toolUseId"]
            tinput = tu["toolUse"].get("input", {})
            logger.info("TOOL CALL: %s %s", name, tinput)
            result = _dispatch(name, tinput, context)
            messages.append({
                "role": "user",
                "content": [{
                    "toolResult": {
                        "toolUseId": tid,
                        "status": "success",
                        "content": [{"text": result}],
                    }
                }],
            })

    return "已达到最大工具调用轮次，仍未形成最终结论。建议人工介入复核。"


# ============================================================================
# FunctionGraph handler（签名：handler(event, context)）
# ============================================================================

def _parse_body(event):
    if not isinstance(event, dict):
        return {}
    if "body" in event and isinstance(event["body"], str):
        try:
            return json.loads(event["body"])
        except Exception:
            return {}
    return event


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, ensure_ascii=False, default=str),
    }


def handler(event, context):
    # 入口首行打印，避免「日志全空」无法排障
    print("=== AIOps AGENT HANDLER ENTRY ===", flush=True)
    try:
        body = _parse_body(event)
        prompt = body.get("prompt") or body.get("message") or event.get("prompt")
        if not prompt:
            return _response(400, {"error": "request body 需要包含 'prompt' 字段"})

        answer = investigate(prompt, context)
        return _response(200, {"answer": answer})
    except Exception as e:
        logger.exception("handler failed")
        import traceback
        return _response(500, {"error": str(e), "traceback": traceback.format_exc()})


if __name__ == "__main__":
    # 本地冒烟测试（不依赖真实凭据/模型，仅验证事件解析与循环骨架）
    test_event = {
        "body": json.dumps({
            "prompt": "demo-5g 命名空间里 AMF Pod 全部 ImagePullBackOff，订阅注册完全中断，排查根因。"
        })
    }
    print(json.dumps(handler(test_event, None), ensure_ascii=False, indent=2))
