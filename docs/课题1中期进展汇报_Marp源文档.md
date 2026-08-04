---
marp: true
size: 16:9
paginate: true
theme: default
footer: '课题1 · 云边端协同的电力专用物联操作系统体系架构设计方案 · 中期进展汇报'
style: |
  :root {
    --navy:#0B3D6B; --navy2:#09315A; --blue:#1E6FB0; --steel:#2C7BC0; --cyan:#3FA7D6;
    --ink:#1B2A3A; --muted:#6B7A8D; --line:#D3DEEA;
    --pale:#EEF4FA; --paleblue:#F5F9FD;
    --green:#1E9E57; --greenp:#E6F5EC; --amber:#C9860F; --amberp:#FBF1DC; --gray:#7A8797; --grayp:#EEF1F4;
    --gold:#C9A227;
  }
  section {
    font-family:"Microsoft YaHei","PingFang SC",Arial,sans-serif; color:var(--ink);
    background:#FFFFFF; padding:44px 54px 52px 54px; position:relative; font-size:18px;
  }
  /* 顶部标题条：细金线 + 深蓝主条 */
  section::before {
    content:""; position:absolute; left:0; top:0; width:100%; height:6px;
    background:linear-gradient(90deg,var(--navy) 0%,var(--blue) 70%,var(--cyan) 100%);
  }
  /* 页脚线 + 页码 */
  section::after { color:#9AA7B5; font-size:11px; right:34px; bottom:16px; }
  footer { color:#8A99A8; font-size:11px; left:54px; bottom:16px; }
  h1 {
    color:var(--navy); font-size:28px; margin:0 0 16px 0; font-weight:700;
    padding:0 0 10px 14px; border-left:7px solid var(--navy); border-bottom:2px solid var(--line);
  }
  h2 { color:var(--navy); font-size:26px; margin:0 0 14px 0; font-weight:700; }
  h3 { color:var(--blue); font-size:18px; margin:10px 0 6px 0; font-weight:700; }
  p, li { font-size:18px; line-height:1.5; }
  ul { margin:6px 0 0 18px; padding-left:8px; }
  li li { font-size:16px; color:#3A4A5A; }
  strong { color:var(--navy); }
  /* 布局 */
  .split { display:grid; grid-template-columns:1fr 1fr; gap:24px; }
  .cols3 { display:grid; grid-template-columns:repeat(3,1fr); gap:16px; }
  /* 卡片：浅蓝底 + 左深蓝条 */
  .card {
    border:1px solid var(--line); border-left:6px solid var(--navy);
    padding:14px 18px; background:var(--paleblue); border-radius:2px;
  }
  .card.blue { border-left-color:var(--blue); }
  .card.amber { border-left-color:var(--amber); background:var(--amberp); }
  /* 强调框 */
  .callout {
    border:1px solid #C6D9EC; border-left:6px solid var(--gold);
    background:#FBF9F0; padding:12px 16px; margin-top:12px; border-radius:2px;
  }
  /* 状态图例 */
  .legend { display:flex; gap:16px; margin-top:14px; font-size:13px; }
  .legend span { padding:4px 12px; border-radius:14px; font-weight:700; }
  .ok { color:var(--green); background:var(--greenp); border:1px solid var(--green); }
  .mid { color:var(--amber); background:var(--amberp); border:1px solid var(--amber); }
  .todo { color:var(--gray); background:var(--grayp); border:1px solid var(--gray); }
  /* 表格：深蓝表头 */
  table { width:100%; border-collapse:collapse; font-size:14px; margin-top:14px; box-shadow:0 1px 3px rgba(11,61,107,.08); }
  th { background:var(--navy); color:#fff; padding:9px 10px; text-align:left; font-weight:700; }
  td { border:1px solid var(--line); padding:8px 10px; vertical-align:middle; }
  tr:nth-child(even) td { background:var(--paleblue); }
  /* 架构图 */
  .arch { display:grid; grid-template-columns:1.15fr 260px; gap:12px; align-items:stretch; margin-top:12px; }
  .planes { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; }
  .layer {
    border:1px solid var(--line); border-left:32px solid var(--navy);
    padding:9px 13px; min-height:42px; font-size:15px; margin-bottom:9px; background:#fff; border-radius:2px;
  }
  .layer br + * , .layer { line-height:1.32; }
  .plane {
    writing-mode:vertical-rl; text-orientation:mixed; border:1px solid #C3D6E8;
    background:var(--pale); display:flex; justify-content:center; align-items:center;
    font-weight:700; font-size:14px; padding:8px; color:var(--navy); border-radius:2px;
  }
  /* 流程步骤 */
  .flow { display:flex; align-items:center; gap:8px; margin-top:18px; flex-wrap:wrap; }
  .step {
    border:1px solid var(--navy); border-radius:6px; padding:8px 14px; font-weight:700;
    color:#fff; background:var(--navy); font-size:15px;
  }
  .arrow { color:var(--blue); font-weight:700; font-size:18px; }
  /* 分层堆叠 */
  .stack .row { border:1px solid var(--line); border-left:6px solid var(--blue); background:var(--paleblue); margin:9px 0; padding:12px 14px; font-weight:700; color:var(--navy); border-radius:2px; }
  /* 时间线 */
  .timeline { display:grid; grid-template-columns:repeat(3,1fr); gap:18px; margin-top:40px; border-top:3px solid var(--navy); padding-top:24px; }
  .milestone { border:1px solid var(--line); border-top:4px solid var(--blue); padding:14px 16px; min-height:112px; background:var(--paleblue); border-radius:2px; }
  .small { font-size:14px; color:var(--muted); }
  /* 架构图内部：层内组件小标签 */
  .zone { border:1px solid var(--line); border-left:8px solid var(--navy); background:#fff; padding:8px 12px; margin-bottom:8px; border-radius:2px; }
  .zone.edge { border-left-color:var(--blue); }
  .zone.end { border-left-color:var(--steel); }
  .zone .zh { font-weight:700; color:var(--navy); font-size:15px; display:inline-block; min-width:52px; }
  .zone .zc { display:inline-block; }
  .chip { display:inline-block; border:1px solid #C3D6E8; background:var(--pale); color:var(--navy); font-size:12.5px; padding:2px 9px; margin:2px 4px 2px 0; border-radius:11px; }
  .coord { background:#0B3D6B; color:#fff; padding:9px 14px; border-radius:2px; margin-bottom:8px; }
  .objchip { display:inline-block; border:1px solid #5C86B0; background:#14477A; color:#fff; font-size:12.5px; padding:2px 10px; margin:2px 4px 2px 0; border-radius:11px; }
  /* 封面与分隔页：flex 居中，可靠不依赖 HTML 定位 */
  section.cover, section.divider {
    display:flex; flex-direction:column; justify-content:center;
    padding:70px 70px; color:#fff;
  }
  section.cover::before, section.divider::before { display:none; }
  section.cover { background:#0B3D6B; align-items:center; text-align:center; }
  section.cover h1 { color:#fff; border:none; padding:0; font-size:34px; line-height:1.4; margin:0 0 18px 0; }
  section.cover h2 { color:#CFE1F2; font-weight:500; font-size:23px; letter-spacing:2px; margin:0 0 34px 0; }
  section.cover p { color:#9FBBD6; font-size:17px; }
  section.cover hr { border:none; border-top:4px solid var(--gold); width:88px; margin:0 auto 28px auto; }
  section.divider { background:#0B3D6B; align-items:flex-start; text-align:left; }
  section.divider.b { background:#09315A; }
  section.divider .tag { color:var(--gold); font-size:20px; font-weight:700; letter-spacing:3px; }
  section.divider .tag::after { content:""; display:block; width:72px; height:4px; background:var(--gold); margin:14px 0 22px 0; }
  section.divider hr { border:none; border-top:4px solid var(--gold); width:72px; margin:14px 0 26px 0; }
  section.divider h1 { color:#fff; border:none; padding:0; font-size:42px; margin:0 0 16px 0; }
  section.divider h2 { color:#CFE1F2; font-size:30px; margin:0 0 14px 0; }
  section.divider p { color:#CFE1F2; font-size:20px; }
---

<!-- _class: cover -->
<!-- _footer: "" -->
<!-- _paginate: false -->

# 云边端协同的电力专用<br/>物联操作系统体系架构设计方案

## 中 期 进 展 汇 报

课题1 · “智能电网”国家科技重大专项　·　二〇二六年

<!-- 讲稿备注：本次汇报两部分——中期已完成的体系架构设计方案；研究内容3安全能力增强机制（内核态飞地）的进展与技术路线。 -->

---

# 汇报提纲

<div class="split">
<div class="card"><strong>一、体系架构设计方案</strong><br/><br/>总体体系架构；云边端三域职责；协同服务层与任务放置</div>
<div class="card blue"><strong>二、研究内容3：安全能力增强机制</strong><br/><br/>内核态飞地架构；我们的工作与飞地的实现现状</div>
</div>


<!-- 讲稿备注：先交代两部分结构和状态标注口径，避免把设计项讲成已完成。 -->

---

<!-- _class: divider -->
<!-- _footer: "" -->

<div class="tag">第一部分</div>

# 体系架构设计方案

云—边—端三域，一个协同服务层，四个横向能力平面

<!-- 讲稿备注：进入第一部分，介绍课题中期完成的体系架构方案。 -->

---

# A-1 研究背景与目标

<div class="split">
<div class="card"><strong>现状与问题</strong><br/>电力物联网中设备类型、处理器架构、操作系统、通信协议都很分散，业务实时等级差异大，安全要求高。以往一台设备一套系统、各自为政，跨设备、跨层级、跨地域的协同难以支撑。</div>
<div>
<strong>课题目标</strong>
<ul>
<li>形成云—边—端三域加协同服务层的统一体系架构</li>
<li>建立任务、算力、数据、通信的多层级协同机制</li>
<li>建立软硬件结合、覆盖全生命周期的安全可信机制</li>
<li>建立覆盖功能、性能、安全、兼容性、可靠性与协同能力的评测体系</li>
</ul>
</div>
</div>

<p style="margin-top:16px;">其中安全可信是四个横向能力平面之一，也是本课题研究内容3的重点，贯穿启动、运行、恢复各阶段。</p>

<!-- 讲稿备注：说明安全是四个横向平面之一，要求软硬件结合、覆盖全生命周期，引出后面的研究内容3。 -->

---

# A-2 总体体系架构

![w:1000](arch-a2.svg)

<!-- 讲稿备注：这一页是总架构图。中间云、边、端三层各有职责与组件；左侧四平面纵向贯穿；右侧协同服务层不是第四层，而是横切三域的中间抽象层，同时对接云、边、端。后面各页从这张图展开。 -->

---

# A-3 三域职责

<div class="cols3">
<div class="card end"><strong>终端</strong>
<ul>
<li>固定优先级抢占、优先级继承</li>
<li>关键任务用静态内存池、有界执行路径</li>
<li>Tickless、休眠唤醒、分级采样降功耗</li>
<li>失联时保留本地安全策略与控制</li>
<li>更新须签名验证、失败回滚、版本追踪</li>
</ul>
</div>
<div class="card"><strong>边缘</strong>
<ul>
<li>协议汇聚、设备管理、数据预处理</li>
<li>嵌入式 Linux 与 RTOS 混合部署</li>
<li>硬件分区/虚拟化划分 CPU、内存、设备</li>
<li>核间经受控共享内存或消息通道通信</li>
<li>优先保证实时域资源预算</li>
</ul>
</div>
<div class="card blue"><strong>云端</strong>
<ul>
<li>跨边缘节点的资源与任务全局视图</li>
<li>按优先级/区域/可信等级生成策略</li>
<li>面向边缘自治的策略预下发</li>
<li>软件包、模型、配置签名化与回滚</li>
<li>安全、性能、故障事件关联分析</li>
</ul>
</div>
</div>

<!-- 讲稿备注：把三域各自的具体机制讲清楚，都来自方案的第6、7、8章。 -->

---

# A-4 协同服务层与任务放置

<div class="split">
<div>
<h3>协同服务层的作用</h3>
<p>位于各域内核与电力业务之间，是整个体系的核心抽象。它把云、边、端上不同操作系统的能力，统一表示为资源、设备、服务、任务、数据五类对象，并提供跨层级的生命周期管理。</p>
<h3>接口分层</h3>
<p>区分业务接口与内核接口，避免上层业务直接依赖某种内核的私有实现；关键接口约定时序、超时、重试、幂等与安全要求。</p>
</div>
<div>
<h3>任务从生成到调整</h3>
<div class="flow" style="flex-direction:column;align-items:flex-start;gap:6px;">
<span class="step">生成 → 画像 → 可行域筛选</span>
<span class="step">分层放置 → 运行监测 → 动态调整</span>
</div>
<h3 style="margin-top:14px;">放置约束（部分）</h3>
<ul>
<li>硬实时与直接设备控制任务留在终端/边缘实时域，不迁往云端</li>
<li>数据敏感任务只放在满足可信等级与数据驻留要求的节点</li>
<li>依赖特定设备/加速器的任务须在具备该能力的节点运行</li>
</ul>
</div>
</div>

<!-- 讲稿备注：协同服务层是体系核心抽象，来自方案第9-11章。任务放置里“可信等级”“可信节点”这些约束，要求节点本身具备安全能力，引出安全平面。 -->

---

<!-- _class: divider b -->
<!-- _footer: "" -->

<div class="tag">第二部分</div>

# 研究内容3：安全能力增强机制

已开展的安全增强工作，以及内核态飞地的概念、架构与实现现状

<!-- 讲稿备注：进入第二部分。先讲中期已做的安全增强工作，再讲内核态飞地。 -->

---

# B-1 目标与要解决的问题

<div class="split">
<div class="card"><strong>研究目标</strong><br/>把强安全语言与内核态飞地结合，做基于硬件隔离的内核态飞地架构，并提出内核组件隔离与程序切片的保护方法，增强内核安全。</div>
<div>
<strong>要解决的问题</strong>
<ul>
<li>常见 TEE 绑定特定厂商，电力设备芯片型号多，难以统一</li>
<li>内核代码量大，任一组件的漏洞都可能影响整个系统</li>
<li>把整个组件都放进飞地代价高，需要更细粒度的保护</li>
</ul>
</div>
</div>

<!-- 讲稿备注：说明这三个问题，引出下一页“飞地是什么”。 -->

---

# B-2 什么是内核态飞地

<div class="split">
<div class="card"><strong>是什么</strong><br/>飞地是内核里一块受保护的区域。即使内核其它部分被攻破，也读写不到飞地内的代码和数据；连管理它的监控器都不能随意读取——这是它区别于普通虚拟机隔离的地方。</div>
<div class="card blue"><strong>和常见 TEE 的不同</strong><br/>不依赖 Intel SGX、AMD SEV、ARM TrustZone 这类厂商专有指令，而是用通用的虚拟化扩展（VMX/SVM 加二级页表 EPT/NPT）来构造，因此不挑芯片厂商。</div>
</div>

<h3>构造方式</h3>
<div class="flow"><span class="step">不可信内核</span><span class="arrow">→</span><span class="step">飞地门</span><span class="arrow">→</span><span class="step">隔离根（监控器）</span><span class="arrow">→</span><span class="step">飞地区域</span></div>

- 隔离根：一个极小的、用 Rust 写的监控器，对应原型中的 axvisor
- 内存隔离：监控器建立二级页表（EPT/NPT）把飞地内存移出内核的地址视图，由 CPU 硬件按表强制执行、内核绕不过
- 受控进出：进出飞地只能走飞地门这个唯一入口

<p class="small" style="margin-top:12px;">内核被攻破也访问不到飞地内存，机密性与完整性由硬件强制保证；基于通用虚拟化扩展，可跨 x86 / ARM / RISC-V / LoongArch，并轻量化适配边、端设备。</p>

<!-- 讲稿备注：合并页——上半讲飞地是什么、和普通虚拟机隔离/厂商TEE的区别；下半讲怎么构造（隔离根+二级页表+飞地门）。跨平台不挑厂商正合电力设备芯片多样。 -->

---

# B-3 我们为飞地打下的地基

飞地依赖三样地基，中期我们已在原型里把它们做出来并完善（以下均为已合并、过 CI 的代码）：

<div class="cols3">
<div class="card"><strong>① 隔离根：良好解耦独立于内核的监控器</strong><br/>axvisor（ArceOS 系、Rust、基于 VMX/SVM）能真正引导并隔离客户机，已在 x86 / ARM / RISC-V / LoongArch 四架构验证。<br/><span class="small">#930 #768 #1207 #788 #883</span></div>
<div class="card blue"><strong>② 二级页表隔离</strong><br/>axvm 建立二级页表（EPT/NPT），由 CPU 硬件强制把客户机内存与宿主隔开，正是飞地隔离飞地内存所用的同一套机制。<br/><span class="small">#1550 #1523 #1467</span></div>
<div class="card amber"><strong>③ 受控内存访问边界</strong><br/>GuestMemoryAccessor + page_prop 让每次访问客户机内存都带边界、带权限，越界在接口层被拦。<br/><span class="small">架构级 trait</span></div>
</div>

<div class="callout"><strong>排查出隔离边界的三个缺口</strong>（均在 ARM VGIC 路径）：GICR_INVLPIR 越界写宿主内存（#1730）、GITS_CBASER 把客户机地址当宿主地址解引用（#1734）、未实现偏移 <code>todo!</code> 触发 hypervisor panic（#1745）。根因同为"信任客户机输入、缺边界校验与 stage-2 翻译"，已给出统一修复方案，修复后开始构建飞地</div>

<!-- 讲稿备注：正面突出三样地基（已跑通、有已合并代码）；底部一句带出主动排查的三个缺口（#1730越界写/#1734越界读/#1745 panic），根因同源、有统一方案，下一步实施。飞地本体是后续。 -->
