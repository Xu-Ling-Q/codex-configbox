# Codex ConfigBox

> 本地 Web UI，一键管理 Codex custom provider 配置。支持多槽位切换、自定义模型、破限配置选择、Fast/Ultra 选项、API 测试。

## 功能

- **多配置槽位**：保存多组 provider 配置（base_url / api_key / model），一键切换
- **自定义模型下拉**：添加 claude-opus-4-8、gork-4.5、deepseek-v4-pro 等非 GPT 模型到 Codex 原生下拉菜单
- **model_instructions_file 自选**：下拉选择破限配置文件，支持手动添加自定义路径
  - system-prompt.md（默认）
  - gpt-unrestricted.md（v0.1.0 破限）
  - gpt-unrestricted-full.md（增强版）
  - codex-keysmith-v0.5.0.md（新版 scenario-routing 破限）
  - 手动添加任意 .md 文件路径
- **协议适配**：Responses / Chat Completions / Anthropic Messages 三种协议自动适配
- **Fast/Ultra**：通过 Provider Plus 同步 Fast tier 和 xhigh/Ultra 推理强度到 Codex
- **同步模型菜单**：一键将自定义模型同步到 Codex 原生下拉菜单
- **自动备份**：每次修改前自动备份 config.toml 和 auth.json
- **API 测试**：获取 /models、探测可用模型、测试 Responses / Messages API
- **会话修复**：切换 provider 后修复 SQLite 线程索引
- **纯本地**：只监听 127.0.0.1:17855，不暴露网络

## 前提条件

- Windows 10/11（PowerShell 5.1+，系统自带）
- Codex CLI / Desktop 已安装（~/.codex/ 目录存在）
- Provider Plus（17856/17857 端口，用于非 GPT 模型协议转换和模型菜单同步）

## 安装

```powershell
git clone https://github.com/Xu-Ling-Q/codex-configbox.git
cd codex-configbox
```

只需两个核心文件：codex-configbox.cmd（启动器）和 codex-configbox.ps1（主脚本）。

## 使用

双击 codex-configbox.cmd，浏览器自动打开 http://127.0.0.1:17855。

### 破限配置切换

1. 勾选「加载 model_instructions_file」
2. 从下拉列表选择配置文件（或选「手动添加」输入自定义路径）
3. 点击「应用当前」写入 config.toml
4. 新会话即加载所选配置

### 自定义模型

1. 在 Model 输入框输入模型 ID（如 claude-opus-4-8）
2. 点击「保存自定义模型」
3. 勾选「同步到 Codex 原生下拉菜单」后应用配置时自动同步

## 相关项目

- [codex-keysmith](https://github.com/Jia-Ethan/codex-keysmith) - Codex 全局指令部署工具
- [Xu-Ling-Q/codex-configbox](https://github.com/Xu-Ling-Q/codex-configbox) - ConfigBox 主仓库
- [Xu-Ling-Q/codex-provider-plus](https://github.com/Xu-Ling-Q/codex-provider-plus) - Provider Plus 协议转换

## License

MIT
