# AxVisor Linux Proc-Macro 依赖版本核对表

本文档用于回答：

- `proc-macro-crate 3.x` 这条最小 vendor 链里
- 哪些依赖可以直接复用本机副本
- 哪些必须切换到 Cargo registry 里的匹配版本

核对对象限定为这 7 个：

1. `proc-macro-crate`
2. `toml_edit`
3. `indexmap`
4. `equivalent`
5. `winnow`
6. `memchr`
7. `hashbrown`

## 1. 结论总表

### 1.1 必须使用 Cargo registry 匹配版本

- `proc-macro-crate`
- `toml_edit`

### 1.2 建议也跟随 Cargo registry 匹配版本

- `indexmap`
- `equivalent`
- `winnow`
- `memchr`
- `hashbrown`

原因不是这些本机副本一定不能用，而是：

- 既然上游主依赖已经固定在 `proc-macro-crate 3.5.0` / `toml_edit 0.25.x`
- 后续最稳妥的是把整条最小链统一到一组 registry 解析出来的兼容版本

## 2. 逐项核对

## 2.1 `proc-macro-crate`

### 当前需求

来自：

- `axvisor_api_proc/Cargo.toml`

声明：

- `proc-macro-crate = "3.1.0"`

### 本机现有版本

Cargo registry 中已确认有：

- `1.3.1`
- `3.5.0`

### 判断

- 应选 `3.5.0`
- 不应使用 `1.x`

### 结论

- 必须使用 Cargo registry 中的 `3.5.0` 线

## 2.2 `toml_edit`

### `proc-macro-crate 3.5.0` 的要求

直接依赖：

- `toml_edit = "0.25.0"`
- `default-features = false`
- `features = ["parse"]`

### 本机现有可见版本

registry 中已确认有：

- `0.25.11+spec-1.1.0`
- `0.25.12+spec-1.1.0`

本机其他仓库现成 vendor 副本看到的是：

- `0.22.27`

### 判断

- `0.22.27` 不应直接复用
- 应切到 `0.25.x`

### 结论

- 必须使用 Cargo registry 中的 `0.25.x`

## 2.3 `indexmap`

### `toml_edit` 的要求

当前 `toml_edit` 看到的是：

- `indexmap = "2.3.0"`

### 本机现有可见版本

registry 中有：

- `2.2.2`
- `2.8.0`
- `2.9.0`
- `2.10.0`
- `2.11.4`
- `2.13.0`
- `2.14.0`

本机其他仓库现成 vendor 副本看到的是：

- `2.11.4`

### 判断

- `2.11.4` 在语义范围内可满足 `2.3.0`
- 但为了与 `toml_edit 0.25.x` 的 registry 链保持一致，建议直接采用 registry 侧匹配版本

### 结论

- 建议使用 Cargo registry 解析链中的版本
- 不建议混用本机旧 vendor 副本

## 2.4 `equivalent`

### `indexmap` 的要求

当前 `indexmap` 需要：

- `equivalent = "1.0"`

### 本机现有可见版本

registry 中有：

- `1.0.1`
- `1.0.2`

本机其他仓库现成 vendor 副本看到的是：

- `1.0.2`

### 判断

- 这个依赖本身很轻
- 本机副本与 registry 都可以满足

### 结论

- 可直接复用 `1.0.2`
- 但若整条链统一走 registry，也可以跟随 registry 一起取

## 2.5 `winnow`

### `toml_edit` 的要求

当前 `toml_edit` 需要：

- `winnow = "0.7.10"`

### 本机现有可见版本

registry 中有：

- `0.7.10`
- `0.7.12`
- `0.7.13`
- `0.7.15`

本机其他仓库现成 vendor 副本看到的是：

- `0.7.13`

### 判断

- `0.7.13` 语义上在兼容范围内
- 但 feature 语义需要严格跟 `toml_edit parse` 路径对齐

### 结论

- 建议跟随 registry 链统一版本

## 2.6 `memchr`

### `winnow` 的关系

`winnow` 对 `memchr` 是 optional，但这条链里应当把它一并冻结。

### 本机现有可见版本

registry 中有：

- `2.7.4`
- `2.7.5`
- `2.7.6`
- `2.8.0`
- `2.8.1`

本机其他仓库现成 vendor 副本看到的是：

- `2.7.6`

### 判断

- `2.7.6` 是可用候选
- 但如果整条链统一，依然建议随 registry 锁定版本

### 结论

- 可复用，但更建议统一 registry 版本

## 2.7 `hashbrown`

### `indexmap` 的要求

当前 `indexmap` 需要：

- `hashbrown = ">= 0.15.0, < 0.17.0"`

### 本机现有可见版本

registry 中有：

- `0.15.2`
- `0.15.3`
- `0.15.5`
- `0.16.0`
- `0.16.1`

本机其他仓库现成 vendor 副本看到的是：

- `0.16.0`

### 判断

- `0.16.0` 在兼容范围内
- 但它本身默认 feature 较重，后续要注意 feature 控制

### 结论

- 可复用 `0.16.0`
- 但更建议跟随 registry 链统一

## 3. 最稳妥的选择

从工程一致性看，当前最稳妥的选择不是：

- `proc-macro-crate` 用 registry
- 其他依赖随手拼本机 vendor 副本

而是：

- 以 `proc-macro-crate 3.5.0` 为锚点
- 用 Cargo registry 里与之相容的一整条最小链

这样能减少两类风险：

1. 版本虽然“看起来兼容”，但 feature/行为细节不完全一致
2. 后面写构建规则时，目录来源过杂，难以追踪问题

## 4. 当前可执行结论

现在已经可以把这条链的建议策略定成：

### 4.1 必选

- `proc-macro-crate`：取 registry `3.5.0`
- `toml_edit`：取 registry `0.25.x`

### 4.2 建议随同统一

- `indexmap`
- `equivalent`
- `winnow`
- `memchr`
- `hashbrown`

也就是说：

- 不再建议把 `arm-gic-driver/vendor/toml_edit 0.22.27`
  直接拿来拼接这条链

## 5. 下一步

有了这张表，下一步最合理的是：

1. 先把这 7 个依赖的“目标版本集合”定死
2. 再开始准备 AxVisor 侧 proc-macro build 规则草案

当前判断：

- 版本核对已经足够支撑下一步进入“规则草案阶段”
