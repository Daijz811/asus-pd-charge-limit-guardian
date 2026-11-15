# 贡献与致谢 / Credits

这是一次由用户持续推进、多个 AI 工具分阶段协助完成的问题调查与工具开发。

| 参与者 / 提供方 | 身份 / 正式模型名称 | 贡献 |
| --- | --- | --- |
| **[Daijz811](https://github.com/Daijz811)** | 项目发起人、维护者与真机验证者 | 提出并复现问题，提供 GU603VV 和外部功率读数；持续校正研究方向，配合及确认真机试验；组织跨工具协作，汇总结果并决定发布。 |
| **OpenAI** | **GPT-6.1 Sol** | 前期公开资料查询、限充/PD/DC 对照整理；ACPI DSDT 与 EC 固件离线分析，追踪停充状态、电流清零及电压目标链；为后续研究提供可复查线索。发布阶段整理中英文说明、贡献记录和离线测试，并补充通信异常处理及状态提示。 |
| **Anthropic** | **Claude Opus 5.5** | 阅读前期聊天记录后，判断大概率存在可行的修复方向并给出建议；完成最终脚本的界面视觉优化。 |
| **Google** | **Gemini 4 Argon** | 完成后续观察、试验与初始脚本，将研究推进到可运行的修复工具。 |

贡献分工依据维护者记录，模型名称已按厂商资料核对。GPT-6.1 Sol 的前期静态分析提供候选控制链，维护者与 Gemini 4 Argon 将后续试验推进到可运行脚本。公开版新增的错误处理仅经过离线模拟验证。

正式名称参考：[OpenAI GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol)、[Anthropic Claude Opus 5.5](https://www.anthropic.com/claude/opus)、[Google Gemini 4 Argon](https://blog.google/innovation-and-ai/technology/developers-tools/build-with-gemini-4-argon/)。

感谢公开分享相关现象和资料的 ASUS / G-Helper 社区用户，以及提供器件和接口文档的厂商与标准组织。引用链接列在[研究记录](docs/INVESTIGATION.md)中；引用不表示对本工具的认可。
