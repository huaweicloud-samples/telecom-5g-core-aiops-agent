"""
华为云 模型抽象层 SDK
====================

本模块提供 ModelProvider 抽象接口和 HuaweiCloudAdapter 实现，
通过华为云 ModelArts MaaS（盘古大模型）的 OpenAI 兼容端点进行对话推理。

使用方式：
    from model_adapter import create_model_client
    client = create_model_client(provider="huaweicloud", region="cn-north-4")
    response = client.converse(model_id="pangu-nlp-2024-12", messages=...)

依赖：pip install openai
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Any, Iterator, Union
import json
import base64
import os


# ============================================================================
# 数据结构（对齐 Bedrock Converse 语义）
# ============================================================================

class StopReason(str, Enum):
    END_TURN = "end_turn"
    TOOL_USE = "tool_use"
    MAX_TOKENS = "max_tokens"
    STOP_SEQUENCE = "stop_sequence"
    GUARDRAIL_INTERVENED = "guardrail_intervened"


@dataclass
class ToolUse:
    """工具调用"""
    tool_use_id: str
    name: str
    input: dict


@dataclass
class ContentBlock:
    """内容块，对齐 Bedrock contentBlock"""
    text: Optional[str] = None
    tool_use: Optional[ToolUse] = None
    image: Optional[dict] = None  # {"format": "png"|"jpeg"|"gif"|"webp", "source": {"bytes": bytes}}


@dataclass
class ConverseResponse:
    """Converse 同步响应，结构与 Bedrock 完全一致"""
    output: dict                    # {"message": {"role": "assistant", "content": [ContentBlock]}}
    stop_reason: str
    usage: dict                     # {"input_tokens": int, "output_tokens": int}
    metrics: dict = field(default_factory=dict)


@dataclass
class ConverseStreamChunk:
    """Converse 流式块"""
    event_type: str                 # messageStart | contentBlockDelta | contentBlockStop | messageStop | metadata
    delta: Optional[dict] = None
    stop_reason: Optional[str] = None
    usage: Optional[dict] = None


# ============================================================================
# 抽象接口
# ============================================================================

class ModelProvider(ABC):
    """模型推理抽象接口，对齐 Bedrock Converse 语义"""

    @abstractmethod
    def converse(
        self,
        messages: list[dict],
        model_id: str,
        system: Optional[str] = None,
        tool_config: Optional[dict] = None,
        inference_config: Optional[dict] = None,
        guardrail_config: Optional[dict] = None,
        **kwargs
    ) -> ConverseResponse:
        """同步对话推理"""
        ...

    @abstractmethod
    def converse_stream(
        self,
        messages: list[dict],
        model_id: str,
        system: Optional[str] = None,
        tool_config: Optional[dict] = None,
        inference_config: Optional[dict] = None,
        **kwargs
    ) -> Iterator[ConverseStreamChunk]:
        """流式对话推理"""
        ...

    @abstractmethod
    def embed(
        self,
        content: Union[str, bytes],
        model_id: str,
        content_type: str = "text"
    ) -> list[float]:
        """嵌入向量生成"""
        ...


# ============================================================================
# Bedrock 模型 ID → 华为云模型 映射表
# ============================================================================

MODEL_MAPPING: dict[str, str] = {
    # 文本对话
    "amazon.nova-pro-v1:0":         "pangu-nlp-2024-12",
    "amazon.nova-lite-v1:0":         "pangu-nlp-lite-2024-12",
    "amazon.nova-micro-v1:0":        "pangu-nlp-micro",
    "anthropic.claude-3-5-sonnet-20241022-v1:0": "pangu-nlp-2024-12",
    "anthropic.claude-3-5-haiku-20241022-v1:0":  "pangu-nlp-lite-2024-12",
    "anthropic.claude-3-opus-20240229-v1:0":    "pangu-nlp-2024-12",
    # 嵌入
    "amazon.nova-embed-text-v1:0":   "pangu-embedding-v1",
    "amazon.titan-embed-text-v2:0":  "pangu-embedding-v1",
    # 多模态
    "amazon.nova-pro-v1:0":          "pangu-multimodal-v1",
}


def map_model_id(bedrock_model_id: str) -> str:
    """将 Bedrock 模型 ID 映射为华为云模型部署名"""
    if bedrock_model_id not in MODEL_MAPPING:
        print(f"[WARN] 模型 {bedrock_model_id} 未在映射表中，原样使用")
        return bedrock_model_id
    return MODEL_MAPPING[bedrock_model_id]


# ============================================================================
# HuaweiCloudAdapter 实现
# ============================================================================

class HuaweiCloudAdapter(ModelProvider):
    """
    华为云适配器：将 Bedrock Converse 语义翻译为 OpenAI 兼容格式，
    通过华为云 MaaS（ModelArts Studio）调用盘古大模型。

    华为云 MaaS 提供 /v1/chat/completions 兼容端点，支持：
    - 标准 Chat Completions 请求/响应
    - Function Calling (tools/tool_calls)
    - 流式响应 (stream=True)
    """

    def __init__(
        self,
        region: str = "cn-north-4",
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
    ):
        self.region = region
        self.api_key = api_key or os.environ.get("HUAWEICLOUD_API_KEY", "")
        # 华为云 MaaS 端点
        self.base_url = base_url or f"https://maas.{region}.myhuaweicloud.com/v1"

        # 延迟初始化 OpenAI 客户端（兼容华为云端点）
        from openai import OpenAI
        self._client = OpenAI(
            base_url=self.base_url,
            api_key=self.api_key,
        )

    # ========================================================================
    # Converse 同步
    # ========================================================================

    def converse(
        self,
        messages: list[dict],
        model_id: str,
        system: Optional[str] = None,
        tool_config: Optional[dict] = None,
        inference_config: Optional[dict] = None,
        guardrail_config: Optional[dict] = None,
        **kwargs
    ) -> ConverseResponse:
        """同步对话推理"""
        # 1. 转换请求
        openai_messages = self._convert_messages_to_openai(messages, system)
        openai_tools = self._convert_tools_to_openai(tool_config) if tool_config else None
        openai_kwargs = self._convert_inference_config(inference_config)

        # 2. 调用华为云 MaaS
        request_kwargs = {
            "model": map_model_id(model_id),
            "messages": openai_messages,
            **openai_kwargs,
        }
        if openai_tools:
            request_kwargs["tools"] = openai_tools

        response = self._client.chat.completions.create(**request_kwargs)

        # 3. 转换响应
        return self._convert_response_from_openai(response)

    # ========================================================================
    # Converse 流式
    # ========================================================================

    def converse_stream(
        self,
        messages: list[dict],
        model_id: str,
        system: Optional[str] = None,
        tool_config: Optional[dict] = None,
        inference_config: Optional[dict] = None,
        **kwargs
    ) -> Iterator[ConverseStreamChunk]:
        """流式对话推理"""
        openai_messages = self._convert_messages_to_openai(messages, system)
        openai_tools = self._convert_tools_to_openai(tool_config) if tool_config else None
        openai_kwargs = self._convert_inference_config(inference_config)

        request_kwargs = {
            "model": map_model_id(model_id),
            "messages": openai_messages,
            "stream": True,
            "stream_options": {"include_usage": True},
            **openai_kwargs,
        }
        if openai_tools:
            request_kwargs["tools"] = openai_tools

        stream = self._client.chat.completions.create(**request_kwargs)

        # 转换流式事件
        tool_call_accumulator: dict[int, dict] = {}

        for chunk in stream:
            if not chunk.choices:
                # 最后一个 chunk 可能只有 usage
                if chunk.usage:
                    yield ConverseStreamChunk(
                        event_type="metadata",
                        usage={
                            "input_tokens": chunk.usage.prompt_tokens,
                            "output_tokens": chunk.usage.completion_tokens,
                        }
                    )
                continue

            delta = chunk.choices[0].delta

            # 首个 chunk：messageStart
            if delta.role == "assistant" and not delta.content and not delta.tool_calls:
                yield ConverseStreamChunk(
                    event_type="messageStart",
                    delta={"role": "assistant"}
                )
                continue

            # 文本 delta
            if delta.content:
                yield ConverseStreamChunk(
                    event_type="contentBlockDelta",
                    delta={"text": delta.content}
                )

            # Tool call delta
            if delta.tool_calls:
                for tc in delta.tool_calls:
                    idx = tc.index
                    if idx not in tool_call_accumulator:
                        tool_call_accumulator[idx] = {
                            "tool_use_id": tc.id,
                            "name": tc.function.name,
                            "input": "",
                        }
                        # 通知新 tool use 开始
                        yield ConverseStreamChunk(
                            event_type="contentBlockDelta",
                            delta={"toolUse": {
                                "tool_use_id": tc.id,
                                "name": tc.function.name,
                                "start": True,
                            }}
                        )
                    # 累积 input JSON 片段
                    tool_call_accumulator[idx]["input"] += tc.function.arguments or ""
                    yield ConverseStreamChunk(
                        event_type="contentBlockDelta",
                        delta={"toolUse": {
                            "tool_use_id": tc.id,
                            "input_delta": tc.function.arguments,
                        }}
                    )

            # finish_reason → messageStop
            finish_reason = chunk.choices[0].finish_reason
            if finish_reason:
                stop_reason = self._map_finish_reason(finish_reason)
                yield ConverseStreamChunk(
                    event_type="messageStop",
                    stop_reason=stop_reason
                )

    # ========================================================================
    # Embed 嵌入
    # ========================================================================

    def embed(
        self,
        content: Union[str, bytes],
        model_id: str,
        content_type: str = "text"
    ) -> list[float]:
        """
        嵌入向量生成。
        - 文本：直接调用盘古 Embedding API
        - 图像：先用盘古多模态生成描述，再文本嵌入（调整方案）
        """
        mapped_model = map_model_id(model_id)

        if content_type == "text":
            response = self._client.embeddings.create(
                model=mapped_model,
                input=content
            )
            return response.data[0].embedding

        elif content_type == "image":
            # 调整方案：图像 → 文本描述 → 嵌入
            description = self._describe_image(content)
            response = self._client.embeddings.create(
                model=mapped_model,
                input=description
            )
            return response.data[0].embedding

        else:
            raise ValueError(f"Unsupported content type: {content_type}")

    def _describe_image(self, image_bytes: bytes) -> str:
        """用盘古多模态模型理解图像，生成文本描述"""
        b64 = base64.b64encode(image_bytes).decode("utf-8")
        response = self._client.chat.completions.create(
            model="pangu-multimodal-v1",
            messages=[{
                "role": "user",
                "content": [
                    {"type": "text", "text": "请详细描述这张图片的内容，用于后续的语义检索。"},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
                ]
            }]
        )
        return response.choices[0].message.content

    # ========================================================================
    # 请求转换：Bedrock Converse → OpenAI Chat Completions
    # ========================================================================

    def _convert_messages_to_openai(
        self,
        bedrock_messages: list[dict],
        system: Optional[str] = None
    ) -> list[dict]:
        """将 Bedrock 消息格式转换为 OpenAI 格式"""
        openai_messages = []

        # system 消息插入首位
        if system:
            openai_messages.append({"role": "system", "content": system})

        for msg in bedrock_messages:
            role = msg["role"]
            content_blocks = msg.get("content", [])

            # 如果 content 是纯文本字符串
            if isinstance(content_blocks, str):
                openai_messages.append({"role": role, "content": content_blocks})
                continue

            # content blocks 数组
            openai_content_parts = []
            tool_calls = []   # assistant 的 toolUse → 顶层 tool_calls（MaaS/openPangu 不认 content 数组里的 tool_call 类型）
            tool_results = []

            for block in content_blocks:
                if "text" in block:
                    openai_content_parts.append({
                        "type": "text",
                        "text": block["text"]
                    })

                elif "image" in block:
                    img = block["image"]
                    fmt = img.get("format", "jpeg")
                    img_bytes = img.get("source", {}).get("bytes", b"")
                    if isinstance(img_bytes, bytes):
                        b64 = base64.b64encode(img_bytes).decode("utf-8")
                    else:
                        b64 = img_bytes  # 假设已是 base64 字符串
                    openai_content_parts.append({
                        "type": "image_url",
                        "image_url": {"url": f"data:image/{fmt};base64,{b64}"}
                    })

                elif "toolUse" in block:
                    # assistant 的 toolUse → OpenAI 顶层 tool_calls（标准格式，不能放 content 数组）
                    tu = block["toolUse"]
                    tool_calls.append({
                        "id": tu["toolUseId"],
                        "type": "function",
                        "function": {
                            "name": tu["name"],
                            "arguments": json.dumps(tu.get("input", {}))
                        }
                    })

                elif "toolResult" in block:
                    # user 的 toolResult → OpenAI tool role message
                    tr = block["toolResult"]
                    tool_results.append({
                        "role": "tool",
                        "tool_call_id": tr["toolUseId"],
                        "content": tr.get("content", [{}])[0].get("text", "")
                    })

            # 组装消息：content 只保留 text/image；tool_calls 放顶层字段
            # 注意：MaaS/openPangu 要求每条消息必须显式带 content 字段（None 会被 openai 序列化省略 → 400 missing 'content'）
            if openai_content_parts:
                if all(p.get("type") == "text" for p in openai_content_parts):
                    text_content = "\n".join(p["text"] for p in openai_content_parts)
                    msg = {"role": role, "content": text_content}
                else:
                    msg = {"role": role, "content": openai_content_parts}
            else:
                msg = {"role": role, "content": ""}   # 空字符串而非 None
            if tool_calls:
                msg["tool_calls"] = tool_calls
            openai_messages.append(msg)

            # tool results 作为独立消息（content 保证非空字符串）
            for tr in tool_results:
                if not tr.get("content"):
                    tr["content"] = "(tool returned no text)"
            openai_messages.extend(tool_results)

        return openai_messages

    def _convert_tools_to_openai(self, tool_config: dict) -> list[dict]:
        """将 Bedrock toolConfig 转换为 OpenAI tools 格式"""
        openai_tools = []
        for tool in tool_config.get("tools", []):
            spec = tool.get("toolSpec", tool)
            openai_tools.append({
                "type": "function",
                "function": {
                    "name": spec.get("name"),
                    "description": spec.get("description", ""),
                    "parameters": spec.get("inputSchema", {}).get("json", {}),
                }
            })
        return openai_tools

    def _convert_inference_config(self, inference_config: Optional[dict]) -> dict:
        """将 Bedrock inferenceConfig 转换为 OpenAI 参数"""
        if not inference_config:
            return {}
        result = {}
        if "maxTokens" in inference_config:
            result["max_tokens"] = inference_config["maxTokens"]
        if "temperature" in inference_config:
            result["temperature"] = inference_config["temperature"]
        if "topP" in inference_config:
            result["top_p"] = inference_config["topP"]
        if "stopSequences" in inference_config:
            result["stop"] = inference_config["stopSequences"]
        return result

    # ========================================================================
    # 响应转换：OpenAI → Bedrock Converse
    # ========================================================================

    def _convert_response_from_openai(self, response) -> ConverseResponse:
        """将 OpenAI 响应转换为 Converse 响应结构"""
        choice = response.choices[0]
        message = choice.message

        content_blocks = []

        # 文本内容
        if message.content:
            content_blocks.append({"text": message.content})

        # Tool calls
        if message.tool_calls:
            for tc in message.tool_calls:
                try:
                    tool_input = json.loads(tc.function.arguments) if tc.function.arguments else {}
                except json.JSONDecodeError:
                    tool_input = {"raw": tc.function.arguments}
                content_blocks.append({
                    "toolUse": {
                        "toolUseId": tc.id,
                        "name": tc.function.name,
                        "input": tool_input,
                    }
                })

        stop_reason = self._map_finish_reason(choice.finish_reason)

        return ConverseResponse(
            output={
                "message": {
                    "role": "assistant",
                    "content": content_blocks,
                }
            },
            stop_reason=stop_reason,
            usage={
                "input_tokens": response.usage.prompt_tokens if response.usage else 0,
                "output_tokens": response.usage.completion_tokens if response.usage else 0,
            },
        )

    def _map_finish_reason(self, finish_reason: Optional[str]) -> str:
        """映射 OpenAI finish_reason → Bedrock stopReason"""
        mapping = {
            "stop": StopReason.END_TURN.value,
            "tool_calls": StopReason.TOOL_USE.value,
            "length": StopReason.MAX_TOKENS.value,
            "stop_sequence": StopReason.STOP_SEQUENCE.value,
            "content_filter": StopReason.GUARDRAIL_INTERVENED.value,
        }
        return mapping.get(finish_reason, StopReason.END_TURN.value)


# ============================================================================
# 工厂函数
# ============================================================================

def create_model_client(
    provider: str = "huaweicloud",
    **kwargs
) -> ModelProvider:
    """
    工厂函数：创建模型客户端。

    provider="huaweicloud" → HuaweiCloudAdapter（盘古大模型，OpenAI 兼容端点）
    """
    if provider == "huaweicloud":
        return HuaweiCloudAdapter(**kwargs)
    else:
        raise ValueError(f"Unknown provider: {provider}")


# ============================================================================
# 工厂函数（见上方 create_model_client）
# ============================================================================
