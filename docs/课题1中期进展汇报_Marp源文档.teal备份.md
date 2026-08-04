---
marp: true
size: 16:9
paginate: true
theme: default
style: |
  :root {
    --navy:#082A44; --blue:#115E8C; --teal:#007A78; --cyan:#00A6D6;
    --ink:#172B3A; --muted:#7B8794; --line:#CBDCE2;
    --pale:#EAF6F8; --green:#1EAD5A; --greenp:#E7F5EC;
    --amber:#D99A22; --amberp:#FFF4D6; --gray:#7B8794; --grayp:#EEF1F4;
  }
  section { font-family: "Microsoft YaHei", "PingFang SC", Arial, sans-serif; color:var(--ink); background:#fff; padding:32px 42px; position:relative; }
  section::before { content:""; position:absolute; left:0; top:0; width:100%; height:10px; background:var(--teal); }
  section::after { color:#9AA7B2; font-size:12px; right:34px; bottom:18px; }
  h1 { color:var(--navy); font-size:30px; margin:0 0 12px 0; font-weight:700; }
  h2 { color:var(--navy); font-size:28px; margin:0 0 14px 0; font-weight:700; }
  h3 { color:var(--teal); font-size:18px; margin:8px 0; }
  p, li { font-size:18px; line-height:1.45; }
  ul { margin:6px 0 0 18px; padding-left:8px; }
  li li { font-size:16px; color:#34495A; }
  strong { color:var(--navy); }
  .cover { background:#F6FBFC; padding:0; text-align:center; }
  .cover .band { position:absolute; top:29%; left:0; width:100%; height:37%; background:var(--teal); }
  .cover h1 { position:absolute; top:38%; left:8%; width:84%; color:#fff; font-size:34px; }
  .cover h2 { position:absolute; top:50%; left:8%; width:84%; color:#EAF7FA; font-size:24px; font-weight:500; }
  .cover .meta { position:absolute; top:72%; left:15%; width:70%; color:var(--navy); font-size:18px; }
  .divider, .divider-b { background:var(--teal); color:#fff; }
  .divider-b { background:var(--navy); }
  .divider h1, .divider-b h1 { color:#fff; font-size:42px; margin-top:190px; }
  .divider p, .divider-b p { color:#D9F4FA; font-size:20px; }
  .split { display:grid; grid-template-columns: 1fr 1fr; gap:26px; }
  .cols3 { display:grid; grid-template-columns: repeat(3,1fr); gap:16px; }
  .card { border:1.4px solid var(--teal); padding:14px 16px; border-left:8px solid var(--teal); background:#fff; }
  .card.blue { border-color:var(--blue); border-left-color:var(--blue); }
  .card.amber { border-color:var(--amber); border-left-color:var(--amber); }
  .callout { border:1.5px solid var(--blue); border-left:8px solid var(--blue); background:#F8FCFD; padding:10px 14px; margin-top:10px; }
  .legend { display:flex; gap:18px; margin-top:12px; font-size:13px; }
  .legend span { padding:4px 12px; border-radius:12px; font-weight:700; }
  .ok { color:var(--green); background:var(--greenp); border:1px solid var(--green); }
  .mid { color:var(--amber); background:var(--amberp); border:1px solid var(--amber); }
  .todo { color:var(--gray); background:var(--grayp); border:1px solid var(--gray); }
  table { width:100%; border-collapse:collapse; font-size:14px; margin-top:12px; }
  th { background:var(--teal); color:#fff; padding:7px; text-align:left; }
  td { border:1px solid var(--line); padding:7px; vertical-align:middle; }
  tr:nth-child(even) td { background:#F8FCFD; }
  .arch { display:grid; grid-template-columns: 1.15fr 260px; gap:12px; align-items:stretch; margin-top:10px; }
  .planes { display:grid; grid-template-columns: repeat(4,1fr); gap:8px; }
  .layer { border:1.3px solid var(--teal); border-left:34px solid var(--teal); padding:7px 11px; min-height:40px; font-size:15px; margin-bottom:8px; }
  .layer br + * , .layer { line-height:1.3; }
  .plane { writing-mode:vertical-rl; text-orientation:mixed; border:1px solid #B8D8DD; background:#D8EFF3; display:flex; justify-content:center; align-items:center; font-weight:700; font-size:14px; padding:8px; }
  .flow { display:flex; align-items:center; gap:8px; margin-top:18px; }
  .step { border:1.5px solid var(--teal); border-radius:8px; padding:8px 12px; font-weight:700; color:var(--teal); background:#fff; font-size:15px; }
  .arrow { color:var(--teal); font-weight:700; }
  .stack .row { border:1.3px solid var(--teal); background:var(--pale); margin:8px 0; padding:12px; font-weight:700; }
  .timeline { display:grid; grid-template-columns: repeat(3,1fr); gap:18px; margin-top:44px; border-top:3px solid var(--teal); padding-top:24px; }
  .milestone { border:1.4px solid var(--teal); padding:14px; min-height:110px; background:#fff; }
  .small { font-size:14px; color:var(--muted); }
---

<!-- _backgroundColor: #007A78 -->
<!-- _color: #ffffff -->

<div style="text-align:center;margin-top:150px;">
<span style="font-size:34px;font-weight:700;color:#fff;">云边端协同的电力专用物联操作系统体系架构设计方案</span><br/><br/>
<span style="font-size:24px;color:#EAF7FA;">中期进展汇报</span><br/><br/><br/>
<span style="font-size:18px;color:#D9F4FA;">课题1 · 2024年度“智能电网”国家科技重大专项　·　二〇二六年</span>
</div>

<!-- 讲稿备注：本次汇报两部分——中期已完成的体系架构设计方案；研究内容3安全能力增强机制（内核态飞地）的进展与技术路线。 -->

---

# 目 录  CONTENTS

<div class="card"><strong>01 板块A：体系架构设计方案</strong><br/>背景目标 / 总体架构 / 三域与协同层 / 安全可信框架 / 成果小结</div>

<div class="card blue"><strong>02 板块B：研究内容3</strong><br/>目标与挑战 / 什么是内核态飞地 / 飞地架构设计 / 组件隔离 / 程序切片 / 实现现状 / 与体系关系 / 计划</div>

<div class="callout"><strong>汇报口径：</strong>状态统一标识为已验证成果、框架待完善、设计或待实现。凡“已合并 PR”的能力按已落地、已过 CI 的原型级验证成果陈述。</div>

<div class="legend"><span class="ok">✅ 已达成并有验证</span><span class="mid">🟡 有框架待完善</span><span class="todo">⬜ 设计或待实现阶段</span></div>

<!-- 讲稿备注：本页先建立汇报结构，并说明后续所有状态标识的统一口径，避免把设计项表述为已验证成果。 -->

---

<!-- _backgroundColor: #007A78 -->
<!-- _color: #ffffff -->

<div style="text-align:left;margin-top:180px;">
<span style="font-size:42px;font-weight:700;color:#fff;">板块A · 体系架构设计方案</span><br/><br/>
<span style="font-size:20px;color:#D9F4FA;">中期产出成果：形成“云—边—端三域 + 协同服务层 + 四横向平面”的统一体系架构</span>
</div>

<!-- 讲稿备注：进入板块A。重点是给出课题1中期完成的体系架构方案。 -->

---

# A-1 研究背景与目标

<div class="split">
<div class="card"><strong>电力物联现状痛点</strong><br/>设备多、处理器架构多、OS 类型多、协议多，实时等级差异大，安全要求高。传统“单设备 / 单 OS / 单业务”模式无法支撑跨设备、跨层级、跨地域协同。</div>
<div>
<strong>目标：形成统一体系架构</strong>
<ul>
<li>形成“云—边—端三域 + 协同服务层 + 四横向平面”的统一体系架构</li>
<li>建立任务 / 算力 / 数据 / 通信的多层级协同机制</li>
<li>建立软硬件结合、贯穿全生命周期的安全可信保障机制</li>
<li>建立覆盖功能、性能、安全、兼容、可靠、协同的评测体系</li>
</ul>
</div>
</div>

<div class="flow"><span class="step">痛点</span><span class="arrow">→</span><span class="step">抽象</span><span class="arrow">→</span><span class="step">协同</span><span class="arrow">→</span><span class="step">评测</span></div>

<div class="callout"><strong>安全工作总目标：</strong>安全是横向平面，要求软硬件结合并覆盖启动、运行、恢复、度量全生命周期。</div>

<!-- 讲稿备注：强调安全是五大设计目标之一，要求软硬件结合、全生命周期。 -->

---

# A-2 总体体系架构

<div class="arch">
<div>
<div class="layer"><strong>云端</strong>　全局治理 / 跨区域编排 / 分析；不进入本地实时闭环</div>
<div class="layer"><strong>边缘</strong>　设备汇聚 / 低时延处理 / 断网自治；混合关键性隔离</div>
<div class="layer"><strong>终端</strong>　实时感知 / 确定性控制；云边失联仍本地自治</div>
<div class="layer" style="background:#082A44;color:white;border-color:#082A44"><strong>协同服务层：</strong>资源 / 设备 / 服务 / 任务 / 数据</div>
</div>
<div class="planes">
<div class="plane">资源与任务</div><div class="plane">数据与通信</div><div class="plane" style="background:#E7F5EC;border-color:#1EAD5A;color:#1EAD5A">安全可信</div><div class="plane">可观测与评测</div>
</div>
</div>

<div class="callout"><strong>核心含义：</strong>协同服务层不替代各域 OS，而是把异构 OS 能力抽象为统一对象，支撑跨域调度、统一治理与安全策略下发。</div>

<!-- 讲稿备注：全场核心图，后续反复回指。三域职责不同，协同服务层横贯三域，四个平面贯穿全栈。 -->

---

# A-3 三域职责与协同计算模型

<div class="cols3">
<div class="card amber"><strong>端</strong><br/>固定优先级抢占、优先级继承、Tickless 低功耗、失联本地自治</div>
<div class="card"><strong>边</strong><br/>混合关键性：实时域与通用域的资源预算与设备隔离</div>
<div class="card blue"><strong>云</strong><br/>策略生成、跨区域编排、跨层级安全 / 性能关联分析</div>
</div>

<h3>任务生命周期闭环</h3>
<div class="flow"><span class="step">生成</span><span class="arrow">→</span><span class="step">画像</span><span class="arrow">→</span><span class="step">可行域筛选</span><span class="arrow">→</span><span class="step">分层放置</span><span class="arrow">→</span><span class="step">监测</span><span class="arrow">→</span><span class="step">动态调整</span></div>

- 放置综合考虑：实时截止期、数据位置、网络质量、可信等级、设备依赖
- 数据敏感任务只能部署在满足可信等级与数据驻留要求的节点

<div class="callout"><strong>自然引出安全平面：</strong>可信等级驱动任务放置，要求节点具备可度量、可隔离、可证明的安全能力。</div>

<!-- 讲稿备注：由“可信等级驱动任务放置”自然引出安全平面。 -->

---

# A-4 安全可信框架（承上启下）

<div class="cols3" style="grid-template-columns:repeat(4,1fr)">
<div class="card"><strong>12.2 语言与组件安全</strong><br/>Rust 内存 / 并发安全；unsafe 最小化封装</div>
<div class="card blue"><strong>12.3 隔离与可信执行</strong><br/>内核组件隔离；内核态飞地 / 虚拟化隔离</div>
<div class="card amber"><strong>12.4 可信启动</strong><br/>启动链度量；可信根与远程证明</div>
<div class="card"><strong>12.5 动态安全与恢复</strong><br/>运行时度量；异常检测与恢复</div>
</div>

<table>
<tr><th>威胁关注重点</th><th>状态</th></tr>
<tr><td>内存与并发缺陷、跨组件越权</td><td><span class="ok">✅ 可控</span></td></tr>
<tr><td>虚拟化逃逸、隔离边界缺口</td><td><span class="mid">🟡 重点</span></td></tr>
<tr><td>异构外设 / AI 加速器可信 I/O</td><td><span class="mid">🟡 重点</span></td></tr>
<tr><td>云端治理、协同编排、通信安全</td><td><span class="todo">⬜ 设计</span></td></tr>
</table>

<div class="callout"><strong>过渡到板块B：</strong>安全可信框架中最能拉开技术深度的是研究内容3的内核态飞地增强机制。</div>

<!-- 讲稿备注：这是 A→B 的过渡页，点明飞地是安全框架里最硬核的部分。 -->

---

# A-5 中期成果覆盖度

**中期成果覆盖度（原型验证集中在端 / 边安全可信段）**

| 能力 | 状态 | 关键证据（已合并 PR） |
|---|---|---|
| Rust 语言 / 内存 / 并发安全 | ✅已达成 | #920 #1120 #1397 #811 |
| 进程 / 容器隔离（seccomp / capabilities / no_new_privs） | ✅已达成 | #1275 #810 #797 |
| 多架构支持 x86 / ARM / RISC-V / LoongArch | ✅已达成 | #930 #768 #1207 #788 #883 |
| 虚拟化隔离边界 | 🟡框架待完善 | 框架 #1550 #1523；已定位缺口 #1730/#1734/#1745 |
| 云端治理 / 协同编排 / 通信安全 | ⬜设计阶段 | 体系设计层面，暂无原型 |

<div class="callout"><strong>汇报边界：</strong>原型验证集中在端 / 边安全可信段；云端协同是体系设计陈述。</div>
<div class="legend"><span class="ok">✅ 已达成并有验证</span><span class="mid">🟡 有框架待完善</span><span class="todo">⬜ 设计或待实现阶段</span></div>

<!-- 讲稿备注：如实划清——原型验证集中在端/边安全可信；云端协同是设计陈述。 -->

---

<!-- _backgroundColor: #082A44 -->
<!-- _color: #ffffff -->

<div style="text-align:left;margin-top:170px;">
<span style="font-size:40px;font-weight:700;color:#fff;">板块B · 研究内容3</span><br/>
<span style="font-size:30px;font-weight:700;color:#EAF7FA;">安全能力增强机制</span><br/><br/>
<span style="font-size:20px;color:#D9F4FA;">内核态飞地：概念、架构设计与当前实现现状</span>
</div>

<!-- 讲稿备注：进入板块B。只讲清楚两件事：内核态飞地是什么；我们目前对飞地的实现情况如何。 -->

---

# B-1 研究内容3 目标与技术挑战

<div class="split">
<div class="card"><strong>目标</strong><br/>基于强安全语言与内核态飞地结合的系统层安全增强机制；设计基于硬件隔离的高安全内核态飞地架构；提出内核组件隔离与程序切片保护方法，增强内核安全保障。</div>
<div>
<strong>技术挑战</strong>
<ul>
<li>传统 TEE 绑定厂商，电力芯片异构难统一</li>
<li>内核庞大，单一漏洞即危及全局</li>
<li>全飞地保护开销大，需精准切片</li>
</ul>
</div>
</div>

<div class="callout"><strong>核心命题：</strong>不绑定硬件厂商，为异构电力设备内核提供飞地级隔离。</div>

<!-- 讲稿备注：核心命题——不绑定硬件厂商，为异构电力设备内核提供飞地级隔离。 -->

---

# B-2 什么是内核态飞地（enclave）

<div class="split">
<div>
<div class="card"><strong>定义</strong><br/>内核态飞地是一块基于硬件隔离的高安全执行区域。即使内核其余部分被攻破，攻击者也无法读写飞地内的代码与数据。</div>
<div class="card blue"><strong>区别</strong><br/>不依赖厂商专有 TEE 指令，而用普遍可得的虚拟化扩展（VMX/SVM + 二级页表 EPT/NPT）构造飞地。</div>
</div>
<div>
<h3>构造原理三要素</h3>
<div class="flow"><span class="step">不可信内核世界</span><span class="arrow">→</span><span class="step">极小 Rust 监控器</span><span class="arrow">→</span><span class="step">受二级页表保护的飞地</span></div>
<ul>
<li>隔离根：极小 Rust 监控器</li>
<li>硬件隔离：EPT/NPT 移除飞地内存视图</li>
<li>受控进出：飞地门是唯一合法通道</li>
<li>可信增强：页表实现可进一步施加形式化验证</li>
</ul>
</div>
</div>

<!-- 讲稿备注：本页只回答“飞地是什么、靠什么隔离”，不涉及任何具体成果或归属。强调“不绑厂商、跨平台”正是电力异构芯片场景的关键价值。 -->

---

# B-3 内核态飞地架构（本课题设计）

- 隔离根 = 极小 Rust hypervisor（对应 axvisor）
- 硬件隔离 = 二级页表（EPT/NPT）把飞地内存移出不可信内核视图
- 受控进出 = 飞地门（gate/trampoline），唯一合法通道

<div class="flow"><span class="step">不可信内核</span><span class="arrow">→</span><span class="step">飞地门</span><span class="arrow">→</span><span class="step">隔离根</span><span class="arrow">→</span><span class="step">飞地区域</span></div>

<div class="split">
<div class="callout"><strong>安全属性：</strong>不可信内核即使被攻破，也无法读写飞地内存；飞地内代码 / 数据机密性与完整性受硬件保护。</div>
<div class="callout"><strong>电力物联适配：</strong>跨 x86 / ARM / RISC-V / LoongArch，轻量化适配边 / 端资源约束。</div>
</div>

<!-- 讲稿备注：强调“跨平台”正是电力异构芯片场景最需要的——不绑厂商。 -->

---

# B-4 内核组件隔离方法（本课题设计）

<div class="split">
<div>
<div class="card"><strong>隔离对象</strong><br/>把高安全内核组件（密钥管理 / 可信 I/O 校验 / 认证）从庞大内核剥离，放入飞地。</div>
<ul>
<li>组件间仅经明确接口交互</li>
<li>受控内存访问器契约返回“宿主物理地址 + 可访问字节数”</li>
<li>攻击面收敛为可枚举、可审计边界</li>
</ul>
</div>
<div class="stack">
<div class="row">访问控制层：LSM 框架</div>
<div class="row">地址空间层：二级页表 / page_prop</div>
<div class="row">语言层：Rust 类型 / 所有权</div>
</div>
</div>

<!-- 讲稿备注：呼应“unsafe/C 集中封装为可审计最小边界”。 -->

---

# B-5 程序切片保护方法（本课题设计）

<div class="card amber"><strong>问题：</strong>整个组件全放进飞地 → 开销大、飞地体积大，可信计算基变大，攻击面可能反增。</div>

<div class="flow"><span class="step">原始内核组件</span><span class="arrow">→</span><span class="step">敏感切片 🔒 进飞地</span><span class="arrow">+</span><span class="step">普通切片 留常规世界</span></div>

- 按数据流 / 控制流分析进行切分
- 敏感切片：触碰密钥、凭证、可信状态的代码与数据 → 进飞地保护
- 普通切片：留常规世界执行
- 收益：保护开销最小化 + 可信计算基最小化 = 安全性与性能兼顾

<!-- 讲稿备注：“最大化增强内核安全保障”里“最大化”的技术含义——精准而非全量保护。 -->

---

# B-6 我们目前对 enclave 的实现现状

**飞地所需的承载地基已基本具备（以已合并 PR 佐证）；飞地与切片本体尚待实现。**

| 飞地机制要素 | 当前实现载体 | 实现状态 |
|---|---|---|
| 隔离根（Rust hypervisor） | axvisor（ArceOS系 · Rust · VMX/SVM） | ✅ 已具备 #930/#768/#1207/#788/#883 |
| 硬件隔离（二级页表 EPT/NPT） | axvm 二级页表 + OS-neutral vCPU | ✅ 已具备 #1550/#1523/#1467 |
| 强安全语言地基 | Rust 全栈 + 内存 / 并发安全 | ✅ 已具备 #920/#1120/#1397/#811 |
| 受控内存边界 | GuestMemoryAccessor + page_prop | ✅ 已具备（架构级 trait） |
| 远程证明 | Asterinas security/tsm | 🟡 有雏形 |
| 飞地本体 / 组件隔离 / 程序切片 | 基于上述地基实现 | ⬜ 待实现 |

<div class="flow"><span class="step">承载地基 ✅ 已具备</span><span class="arrow">→</span><span class="step">本课题落地</span><span class="arrow">→</span><span class="step">飞地 / 切片本体 ⬜ 待实现</span></div>

<!-- 讲稿备注：全场最重要一页。结论：飞地运行所依赖的隔离根、二级页表、强安全语言等地基均已具备且有已合并 CI 证据；飞地与切片本体是下一步工作，路径清晰、风险可控。 -->

---

# B-7 与体系架构的关系（回指 A-2）

<div class="split">
<div>
<div class="card"><strong>体系位置</strong><br/>飞地机制服务于四平面中的“安全可信”，主要落在端 / 边节点。</div>
<ul>
<li>直接应对虚拟化逃逸风险</li>
<li>面向异构外设 / AI 加速器可信 I/O</li>
<li>可承载可信启动度量根与远程证明</li>
</ul>
</div>
<div class="arch">
<div>
<div class="layer">云端：治理 / 编排 / 分析</div>
<div class="layer">边缘：汇聚 / 低时延 / 隔离</div>
<div class="layer">终端：实时感知 / 确定性控制</div>
</div>
<div class="planes">
<div class="plane">资源与任务</div><div class="plane">数据与通信</div><div class="plane" style="background:#E7F5EC;border-color:#1EAD5A;color:#1EAD5A">安全可信 · 飞地落点</div><div class="plane">可观测与评测</div>
</div>
</div>
</div>

<div class="callout"><strong>缺口方向：</strong>虚拟化逃逸（#1730/#1734/#1745）与异构外设 / AI 加速器可信 I/O（#1732/#1739/#1762）是后续飞地能力的重要落点。</div>

<!-- 讲稿备注：让评审看到研究内容3不是孤立点，而是嵌进整体体系的关键安全底座。 -->

---

# B-8 下一阶段计划

<div class="timeline">
<div class="milestone"><strong>近期：最小内核态飞地</strong><br/>axvisor 上实现隔离根 + 二级页表隔离 + 飞地门，单架构打通。</div>
<div class="milestone"><strong>中期：组件隔离与切片工具</strong><br/>实现内核组件隔离、程序切片分析工具，并接入 tsm 远程证明。</div>
<div class="milestone"><strong>远期：多架构与典型业务验证</strong><br/>多架构飞地 + 页表形式化验证 + 电力典型业务验证。</div>
</div>

<div class="callout"><strong>交付拆解：</strong>最小可运行飞地 → 组件隔离 / 切片工具 → 多架构与典型业务验证。</div>

<!-- 讲稿备注：把飞地落地拆成可交付里程碑，呼应“最大化增强内核安全保障”。 -->

---

# 汇报完毕，谢谢！

<div style="text-align:center;margin-top:130px;font-size:24px;color:var(--navy);font-weight:700">概念清晰 + 地基已具备 + 落地路径明确</div>

<div class="callout" style="margin-top:42px">体系架构方案已成形并有原型验证；研究内容3已讲清内核态飞地原理，且飞地所需的强安全语言、Rust hypervisor、二级页表隔离等承载地基均已在原型中具备，飞地本体为下一步工作。</div>

<!-- 讲稿备注：结束页用一句话收束：体系架构已经形成，安全增强机制的概念与技术路线清晰，支撑飞地实现的地基已经具备，飞地本体是下一步明确工作。 -->
