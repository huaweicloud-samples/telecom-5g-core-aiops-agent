# =============================================================================
# build_and_deploy.py — 打包并部署 AIOps 智能体函数到 FunctionGraph
# -----------------------------------------------------------------------------
# 打包注意：
#  - 自带 SDK 依赖（huaweicloudsdk* + openai），且必须锁定 Linux x86_64 /
#    Python3.9 纯 Python 轮子（打包机若是 Windows/mac/arm 会拉错平台原生模块）。
#  - 过滤 __pycache__ / *.dist-info / *.egg-info / tests / py.typed。
#  - 两道护栏：缺 huaweicloudsdkcore 直接报错退出；产物 < 200KB 报错（仅
#    index.py 约 3KB，带 SDK 应 > 2MB，避免「日志全空」的静默崩溃）。
#  - obs / cryptography 原生模块华为云 FGS 已内置，绝不自带（否则日志全空）。
#  - 代码上传到 OBS（code_type=obs），由 agent.tf 的桶策略放行 agency 读取。
# =============================================================================

import argparse
import os
import sys
import shutil
import subprocess
import zipfile
import json

HERE = os.path.dirname(os.path.abspath(__file__))

# 函数运行期：Python3.9 / Linux x86_64。轮子平台与版本必须对齐（纯 Python 即可，
# SDK 走 HMAC 签名，不依赖 cryptography 原生加速器）。
PYTHON_VERSION = "39"
PLATFORM = "manylinux2014_x86_64"

# 运行期必须自带的依赖（FGS 不内置 huaweicloudsdk*；openai 用于调用盘古 MaaS）
DEPENDENCIES = [
    "huaweicloudsdkcore",
    "huaweicloudsdkces",
    "huaweicloudsdkvpc",
    "huaweicloudsdkcts",
    "openai",
]

# 上传用（本地运行，用户真实凭据）：OBS SDK
UPLOAD_DEPENDENCIES = ["huaweicloudsdkobs"]


def run(cmd):
    print("+ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def install_deps(target, packages):
    """用平台锁定的纯 Python 轮子安装依赖到 target 目录。"""
    pip = [sys.executable, "-m", "pip", "install",
           "--target", target,
           "--platform", PLATFORM,
           "--python-version", PYTHON_VERSION,
           "--only-binary=:all:",
           "--no-deps"]
    # 先装运行期依赖（含各自的纯 Python 传递依赖，逐一指定以避免拉错平台）
    for pkg in packages:
        run(pip + [pkg])


def build_zip(build_dir, zip_path):
    """把 index.py / model_adapter.py 与依赖一起打成 zip，并做护栏检查。"""
    os.makedirs(build_dir, exist_ok=True)

    # 1) 复制源码到构建根目录
    for f in ("index.py", "model_adapter.py"):
        src = os.path.join(HERE, f)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(build_dir, f))

    # 2) 安装运行期依赖
    vendor = os.path.join(build_dir, "vendor")
    install_deps(vendor, DEPENDENCIES)
    # 依赖直接放在 zip 根（FGS 只把函数根加进 sys.path，不会加子目录）
    for name in os.listdir(vendor):
        s = os.path.join(vendor, name)
        d = os.path.join(build_dir, name)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy(s, d)
    shutil.rmtree(vendor, ignore_errors=True)

    # 3) 过滤不需要的文件
    for root, dirs, files in os.walk(build_dir):
        for d in list(dirs):
            if d in ("__pycache__", "tests", "test") or d.endswith(".dist-info") or d.endswith(".egg-info"):
                shutil.rmtree(os.path.join(root, d), ignore_errors=True)
                dirs.remove(d)
        for f in files:
            if f.endswith(".pyc") or f == "py.typed":
                os.remove(os.path.join(root, f))

    # 4) 护栏 1：缺核心 SDK 直接报错
    if not os.path.exists(os.path.join(build_dir, "huaweicloudsdkcore")):
        print("ERROR: 未成功打包 huaweicloudsdkcore —— 函数运行期将因 import 失败而日志全空。"
              "请检查 pip 安装是否成功（需能访问 PyPI 或镜像）。", file=sys.stderr)
        sys.exit(1)

    # 5) 打包
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(build_dir):
            for f in files:
                fp = os.path.join(root, f)
                arc = os.path.relpath(fp, build_dir)
                z.write(fp, arc)

    size = os.path.getsize(zip_path)
    # 护栏 2：体积过小说明几乎没打进依赖
    if size < 200 * 1024:
        print(f"ERROR: 产物仅 {size/1024:.0f}KB，疑似未打进 SDK 依赖（正常应 > 2MB）。", file=sys.stderr)
        sys.exit(1)
    print(f"✓ 打包完成：{zip_path} ({size/1024:.0f}KB)")


def upload_to_obs(region, bucket, zip_path, object_key="agent.zip"):
    """用用户真实凭据把 zip 上传到 OBS 代码桶（agent.tf 桶策略放行 agency 读取）。"""
    install_deps_for_upload()
    from huaweicloudsdkcore.auth.credentials import BasicCredentials
    from huaweicloudsdkobs.v2 import ObsClient

    ak = os.environ.get("HW_ACCESS_KEY")
    sk = os.environ.get("HW_SECRET_KEY")
    if not ak or not sk:
        print("ERROR: 上传需要 HW_ACCESS_KEY / HW_SECRET_KEY 环境变量（用户真实凭据，切勿硬编码）。", file=sys.stderr)
        sys.exit(1)

    endpoint = f"https://obs.{region}.myhuaweicloud.com"
    client = ObsClient(access_key_id=ak, secret_access_key=sk, server=endpoint)
    print(f"+ uploading {zip_path} -> obs://{bucket}/{object_key}", flush=True)
    resp = client.putFile(bucket, object_key, zip_path)
    if resp.status < 300:
        print(f"✓ 上传成功：https://{bucket}.obs.{region}.myhuaweicloud.com/{object_key}")
    else:
        print(f"ERROR: 上传失败 status={resp.status}", file=sys.stderr)
        sys.exit(1)


_UPLOAD_DEPS_READY = False


def install_deps_for_upload():
    global _UPLOAD_DEPS_READY
    if _UPLOAD_DEPS_READY:
        return
    # 上传用的 OBS SDK 装在临时目录，不污染构建产物
    tmp = os.path.join(HERE, ".upload_vendor")
    os.makedirs(tmp, exist_ok=True)
    try:
        install_deps(tmp, UPLOAD_DEPENDENCIES)
        sys.path.insert(0, tmp)
    finally:
        _UPLOAD_DEPS_READY = True


def resolve_bucket(region, bucket_arg):
    if bucket_arg:
        return bucket_arg
    # 优先从 terraform output 读（需已 apply）
    try:
        out = subprocess.check_output(
            ["terraform", "-chdir", os.path.join(HERE, "..", "..", "infra"),
             "output", "-raw", "fgs_code_bucket"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        if out:
            return out
    except Exception:
        pass
    return f"devops-agent-5g-fgs-code"


def main():
    ap = argparse.ArgumentParser(description="Build & deploy the AIOps agent function")
    ap.add_argument("--region", default=os.environ.get("REGION", "cn-north-4"))
    ap.add_argument("--bucket", default=None, help="OBS 代码桶名（默认读 terraform output）")
    ap.add_argument("--build-dir", default=os.path.join(HERE, "build"))
    ap.add_argument("--zip", default=os.path.join(HERE, "build", "agent.zip"))
    ap.add_argument("--no-upload", action="store_true", help="只打包不上传")
    ap.add_argument("--skip-deps", action="store_true", help="跳过 pip 安装（依赖已存在时）")
    args = ap.parse_args()

    build_zip(args.build_dir, args.zip)

    if args.no_upload:
        print("✓ 跳过上传（--no-upload）")
        return

    bucket = resolve_bucket(args.region, args.bucket)
    upload_to_obs(args.region, bucket, args.zip)


if __name__ == "__main__":
    main()
