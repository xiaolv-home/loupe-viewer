import Foundation

/// The 技能市场: skills on GitHub that were read through before being listed — substantive
/// method, not a one-paragraph prompt — and whose licence allows use. Checked 2026-10.
enum SkillCatalog {
    struct Entry: Identifiable, Hashable {
        var id: String { url }
        let category: String
        let title: String
        let summary: String
        let url: String
        var tags: [String] = []
    }

    static let categories = ["文档与办公", "法务与合同", "求职与简历", "写作与公文", "财务与会计", "学术与论文", "产品、咨询与营销", "图表与可视化", "自己做技能"]

    static let entries: [Entry] = [
        // 文档与办公
        Entry(category: "文档与办公", title: "Office 文档处理（Word / Excel / PPT / PDF）",
              summary: "读写、编辑、批注 docx，生成带公式与格式的 xlsx，制作 pptx，PDF 拆分合并、填表、提取表格。附带脚本，需要开启「允许 AI 运行终端命令」并装有 Python。",
              url: "https://github.com/appautomaton/document-SKILLs", tags: ["MIT", "4 个技能", "需 Python"]),
        Entry(category: "文档与办公", title: "学术办公：论文阅读报告、学术 PPT 与 Word",
              summary: "把论文读成结构化报告，生成组会 / 答辩 PPT 和 Word 文档；另含科研写作与科学计算工具集。",
              url: "https://github.com/zLanqing/codex-claude-academic-skills", tags: ["MIT", "5k★", "中文"]),
        Entry(category: "文档与办公", title: "日报 / 周报 / 月报生成",
              summary: "把零散的工作记录整理成结构清楚、有数据有结论的职场汇报。",
              url: "https://github.com/freestylefly/daily-reporter-skill", tags: ["MIT", "中文"]),

        // 法务与合同
        Entry(category: "法务与合同", title: "中国企业法务顾问（含法规库）",
              summary: "合同审查与起草、法律风险分析、数据 / 广告 / AI / 知识产权合规；内置民法典、公司法、个人信息保护法等官方法规全文，AI 可以检索原文作为依据。",
              url: "https://github.com/Daknniel-0881/qulv-china-legal-counsel-skill", tags: ["MIT", "中文", "法规库 26MB"]),
        Entry(category: "法务与合同", title: "国企 / 央企合同合规审查",
              summary: "在通用合同风险审查之上，叠加国资监管框架下的 9 大合规核查维度，适合国企法务、合规与风控。",
              url: "https://github.com/HsuanZhao/SOE-Legal-Checker", tags: ["MIT", "中文"]),
        Entry(category: "法务与合同", title: "英文合同审查（CUAD 风险识别）",
              summary: "按 CUAD 41 类风险条款逐条识别英文合同问题，给出市场惯例对比和律师式修改建议。",
              url: "https://github.com/evolsb/claude-legal-skill", tags: ["MIT", "英文合同"]),

        // 求职与简历
        Entry(category: "求职与简历", title: "简历审计与优化",
              summary: "站在招聘方视角找出会被刷掉的问题，把职责型描述改成成果型、量化表达，结合 JD 调整关键词，可压成一页简历。不编造经历。",
              url: "https://github.com/wyh0626/resume-optimizer", tags: ["MIT", "中文", "533★"]),
        Entry(category: "求职与简历", title: "求职全流程（简历 / 投递 / 面试）",
              summary: "简历优化、岗位匹配、模拟面试与复盘、投递跟踪等一整套求职技能。",
              url: "https://github.com/Hisn00w/ASu-skills", tags: ["MIT", "中文", "5.9k★"]),
        Entry(category: "求职与简历", title: "JobOK：证据驱动的求职助手",
              summary: "从经历里挖掘优势证据，做岗位匹配度分析、简历优化和面试训练。",
              url: "https://github.com/GresonKwan/JobOK", tags: ["MIT", "中文"]),

        // 写作与公文
        Entry(category: "写作与公文", title: "公文写作（按《人民日报》等语料总结）",
              summary: "按文种、场景和材料生成结构规范、表达稳妥、内容具体、去 AI 味的公文。",
              url: "https://github.com/Liuxiangjian-ai/official-document-skill", tags: ["MIT", "中文"]),
        Entry(category: "写作与公文", title: "党政机关公文（GB/T 9704-2012）",
              summary: "按国家标准的文种、要素、格式写通知、请示、报告、函、纪要等，附格式规范与检查清单。",
              url: "https://github.com/KaguraNanaga/official-document-writing-skill", tags: ["MIT", "中文"]),
        Entry(category: "写作与公文", title: "小红书图文策划",
              summary: "先判断内容任务，再选视觉风格，输出完整图文结构、逐页视觉方案、配图提示词、发布文案和自检。",
              url: "https://github.com/ziguishian/xhs-visual-director-skill", tags: ["MIT", "中文", "1.4k★"]),

        // 财务与会计
        Entry(category: "财务与会计", title: "中国会计准则财务技能包",
              summary: "记账、理账、报表、税务、审计 25 个技能，覆盖小企业会计准则与中国注册会计师审计准则。配合 Loupe 的表格计算工具使用效果最好。",
              url: "https://github.com/kylin985ti/china-accounting-skills", tags: ["MIT", "中文", "25 个技能"]),

        // 学术与论文
        Entry(category: "学术与论文", title: "科研论文写作助手",
              summary: "覆盖论文写作全流程的 30 个模板：中英互译、润色、文献综述、审稿回复、基金申请。",
              url: "https://github.com/alfonso0512/research-writing-skill", tags: ["MIT", "中文"]),
        Entry(category: "学术与论文", title: "人文社科学位论文",
              summary: "从选题、文献、框架到写作与投稿的人文社科论文全流程方法。",
              url: "https://github.com/ganzhi-black/humanities-thesis-skill", tags: ["MIT", "中文"]),
        Entry(category: "学术与论文", title: "IEEE 论文工具集",
              summary: "IEEE 风格的写作、润色、审稿、实验设计、图表、LaTeX、引用与论文阅读，共 10 个技能。",
              url: "https://github.com/CloudWave818/ieee-skills", tags: ["MIT", "10 个技能"]),

        // 产品、咨询与营销
        Entry(category: "产品、咨询与营销", title: "麦肯锡式问题分析与报告",
              summary: "假设驱动的结构化分析：MECE、议题树拆解、Dummy Page 设计、数据收集，产出咨询风格的研究报告与 PPT 大纲。",
              url: "https://github.com/fleurytian/awesome-claude-skills/tree/main/mckinsey-consultant-11", tags: ["MIT", "中文"]),
        Entry(category: "产品、咨询与营销", title: "产品经理技能框架",
              summary: "PRD 评审、需求优先级、用户研究、指标诊断、路线图等 77 个产品方法技能。",
              url: "https://github.com/deanpeters/Product-Manager-Skills", tags: ["CC BY-NC-SA（非商用）", "7.6k★", "英文"]),
        Entry(category: "产品、咨询与营销", title: "营销技能全集",
              summary: "转化率优化、文案、SEO、广告创意、A/B 测试、数据分析等 50 多个营销技能。",
              url: "https://github.com/coreyhaines31/marketingskills", tags: ["MIT", "56k★", "英文"]),

        // 图表与可视化
        Entry(category: "图表与可视化", title: "流程图 / 思维导图 / 白板图",
              summary: "把文字整理成 Mermaid 图、Excalidraw 手绘图和 Obsidian Canvas。",
              url: "https://github.com/axtonliu/axton-obsidian-visual-skills", tags: ["MIT", "3.6k★"]),
        Entry(category: "图表与可视化", title: "Mermaid 全图种",
              summary: "流程图、时序图、甘特图、类图、状态图、ER 图等全部 Mermaid 图种的写法与规范。",
              url: "https://github.com/WH-2099/mermaid-skill", tags: ["MIT"]),

        // 自己做技能
        Entry(category: "自己做技能", title: "技能制作向导（Anthropic 官方）",
              summary: "教 AI 帮你把自己的工作方法写成一个新技能（SKILL.md + 参考资料），并测试改进。",
              url: "https://github.com/anthropics/skills/tree/main/skills/skill-creator", tags: ["Apache-2.0", "官方"])
    ]
}
