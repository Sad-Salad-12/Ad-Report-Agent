# 脱敏测试集 / Anonymized test sets

这 5 个文件夹均可独立拖入 Ad Report Agent。每个文件夹只含软件需要的 8 个输入文件；不需要压缩，也不依赖其他测试集先运行。

All five folders are independently runnable in Ad Report Agent. Each folder contains exactly the eight required inputs and can be selected directly without creating a ZIP.

| 文件夹 / Folder | 情景 / Scenario | Spend | Purchase value | Purchases | Adds to cart | ROAS |
|---|---|---:|---:|---:|---:|---:|
| 01_balanced_baseline | 均衡基线 / Balanced baseline | 3020 | 6308 | 39 | 192 | 2.09 |
| 02_growth_surge | 增长加速 / Growth surge | 3375 | 7931 | 48 | 228 | 2.35 |
| 03_efficiency_gain | 效率提升 / Efficiency gain | 3150 | 8505 | 52 | 241 | 2.7 |
| 04_traffic_spike | 流量激增 / Traffic spike | 4100 | 7380 | 44 | 260 | 1.8 |
| 05_conversion_recovery | 转化恢复 / Conversion recovery | 2890 | 6849 | 43 | 205 | 2.37 |

## 使用方法 / How to use

1. 在 App 中点击“选择素材文件夹 / Choose input folder”。
2. 选择任意一个编号文件夹，而不是本目录的最外层。
3. 等待显示 8/8 后生成报告。
4. 如需并排比较结果，请为不同测试集选择不同输出目录；五套数据使用同一个合成周期，报告文件名可能相同。

## 脱敏边界 / Privacy

- 品牌、市场、地区、产品、活动、受众、创意和关键词均为通用代号。
- 日期与所有业务指标均为合成值；五种情景只保留原周报的字段结构和合理业务关系。
- 每套包含 24 条合成创意和 1,000 条合成关键词，不复刻原始样本规模。
- 所有派生指标均由合成基础指标重新计算。
