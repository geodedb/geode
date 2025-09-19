# Research Prompt — _Grey Cardinal Analysis in Graphs_

_(Hidden pivot detection for cybersecurity and beyond)_

## 1) Executive Summary (≤200 words)

We define **grey cardinals** as nodes whose **local footprint is small** (e.g., low degree, low community “core”) yet which exercise **disproportionate global control** over paths, flows, and percolation. We propose a composite **Grey Cardinal Score (GCS)** fusing **path‑based centralities** (shortest‑path and current‑flow betweenness), **bridge structure** (bridging centrality, articulation/vertex‑cut likelihood), **core/periphery tension** (low k‑core/truss vs. high control), **dominator relations**, and **temporal betweenness** on **time‑respecting paths**. Efficient implementations combine exact algorithms (Brandes; Tarjan; min‑cut/flow), scalable approximations (KADABRA/ABRA), and temporal variants. In cybersecurity, model **hosts/accounts/processes** as a (heterogeneous, temporal) graph; score potential **pivot nodes** used in **lateral movement** (MITRE ATT\&CK TA0008). Evaluate on operational datasets (e.g., **LANL Unified Host & Network**) and red‑team traces. The output is a ranked list of candidate pivot systems/identities plus **explainable graph evidence** (paths, cuts dominated, temporal surges). Evidence strength is high for algorithms (foundational) and medium for domain validation (dataset/baseline differences). ([Taylor & Francis Online][1])

---

## 2) Background & Context

**Concept.** A _grey cardinal_ is analogous to a behind‑the‑scenes power broker in networks: **low degree/visibility** but **high control** over flows and inter‑community connectivity. Formal signatures include: high **betweenness** (exact or current‑flow/random‑walk variants), high **bridging centrality**, presence in **critical cuts** (edge/vertex), **domination** of many time‑respecting paths, and **low local cohesion** (k‑core/k‑truss) despite high global influence. ([Taylor & Francis Online][1])

**Foundational algorithms.**

- **Betweenness centrality**: Brandes’ algorithm runs in $O(|V||E|)$ (unweighted) / $O(|V||E|+|V|^2\log|V|)$ (weighted). ([Taylor & Francis Online][1])
- **Current‑flow & random‑walk betweenness**: model information flow as electrical current/random walks; exact + randomized approximations. ([kops.uni-konstanz.de][2])
- **Bridging centrality & localized variant**: combine betweenness with a local bridging coefficient; LBC approximates with local info. ([BibSonomy][3])
- **Core/periphery**: linear‑time **k‑core** decomposition; **k‑truss** as stronger cohesiveness filter. ([arXiv][4])
- **Articulation points / biconnected components** (cut vertices/bridges): linear‑time DFS (Tarjan). ([ACM Digital Library][5])
- **Dominators in directed graphs**: near‑linear/linear algorithms (Lengauer–Tarjan; later refinements). ([Princeton University][6])
- **Min‑cut/max‑flow** toolkit\*\*:\*\* flows, cuts, disjoint paths, preflow‑push; classic reductions (e.g., node‑splitting for vertex cuts). (Textbook coverage). &#x20;

**Temporal networks.** Grey influence can be **episodic**: _temporal betweenness_ uses **time‑respecting** paths and “foremost/fastest” journeys. ([Physical Review Journals][7])

**Cybersecurity context.** Adversaries perform **lateral movement** and **pivot** through hosts/accounts (ATT\&CK **TA0008**). Research shows graph methods detect lateral movement from authentication/NetFlow logs via **graph anomaly detection**, **link prediction**, and **subgraph classification**. Tools such as **BloodHound** illustrate attacker pathfinding in AD. ([MITRE ATT\&CK][8])

---

## 3) Core Findings (What to measure, Why it matters, Evidence strength, Dissent)

### Theme A — Path/flow control beyond degree

- **What we know.** Nodes can exhibit **high betweenness/control** with **low degree**; current‑flow/random‑walk variants capture non‑geodesic routing. **Approximations** (KADABRA/ABRA) scale to large graphs with accuracy guarantees. **Why it matters.** Such nodes quietly **broker** many paths—typical for pivots and _stepping‑stones_. **Evidence strength:** High (multiple Tier‑A sources). **Dissent:** Betweenness is sensitive to noise; temporal and multi‑layer paths may dilute static scores. ([Taylor & Francis Online][1])

### Theme B — Bridging & structural holes

- **What we know.** **Bridging centrality** and related measures identify **connectors of communities** (structural hole theory). **Why it matters.** Pivots often connect **otherwise distant** subgraphs (e.g., user VLAN → server enclave). **Evidence strength:** Medium‑High. **Dissent:** Bridging metrics may co‑vary with degree; normalize with leverage/constraint. ([BibSonomy][3])

### Theme C — Critical cuts & dominators

- **What we know.** **Articulation points**, **s‑t vertex/edge cuts**, and **dominator trees** formalize **choke points**; min‑cut equals max‑flow; reductions enable **vertex‑cut** detection. **Why it matters.** Removing a grey cardinal **severs** attacker reachability. **Evidence strength:** High (classical). **Dissent:** In noisy enterprise graphs, small cuts abound; constrain to **attacker/target sets** and **time windows**. ([Princeton University][6])

### Theme D — Temporal influence

- **What we know.** **Temporal betweenness** on **foremost/fastest** paths better reflects real operations; surges in **Δ‑betweenness** indicate **on‑demand pivoting**. **Why it matters.** Pivots are often **short‑lived** (post‑exploitation windows). **Evidence strength:** Medium (developing but solid). **Dissent:** Algorithmic cost is high; requires careful windowing. ([Physical Review Journals][7])

### Theme E — Empirical cybersecurity efficacy

- **What we know.** Graph‑based methods detect **lateral movement** from auth graphs and NetFlow; **stepping‑stone** literature validates _pivot‑through_ behavior via traffic correlation (incl. encrypted). **Why it matters.** Directly maps to **TA0008** detections with explainable artifacts (paths/cuts). **Evidence strength:** Medium (varied datasets). **Dissent:** Class imbalance and environment drift; need baselines and labels (e.g., red‑team markers). ([USENIX][9])

---

## 4) Methodological Considerations (data quality, bias, caveats)

- **Graph modeling choices matter.** Use **heterogeneous, temporal, multi‑layer graphs** (user↔host↔process↔IP/DNS). Aberrant _mapping_ (e.g., NAT, load balancers) can inflate or hide control nodes. (Assumption: Windows‑heavy enterprises).
- **Noise & missingness.** Sparse logs, clock skew, and credential replay blur causality; prefer **time‑respecting** paths and **current‑flow** metrics to reduce shortest‑path brittleness. ([kops.uni-konstanz.de][2])
- **Scalability.** Exact betweenness is expensive; use **KADABRA/ABRA**, GPU or parallel Brandes, and **sampling** with error bounds. ([arXiv][10])
- **Confounding roles.** Domain controllers, proxies, and jump hosts are _intended_ pivots; calibrate with **role filters** and **expected‑pivot** whitelists from CMDB/AD.
- **Evaluation data.** Prefer datasets with **red‑team ground truth** (e.g., **LANL 2015** includes red events) and **2017 Unified Host & Network** for scale. ([OSTI][11])

---

## 5) Detailed Research Plan (Search Plan → Algorithms → Evaluation)

### 5.1 Research Questions & Hypotheses

- **RQ1.** Which composite features best identify _grey cardinals_ (hidden pivots) across static and temporal graphs?
- **H1.** Nodes with **low k‑core/k‑truss** yet **high** (current‑flow) **betweenness**/**bridging** and **s‑t cut** membership are enriched for pivots. ([ADS][12])
- **RQ2.** Do **temporal betweenness surges** and **dominator‑set coverage** improve precision for short‑lived pivots? ([ACM Digital Library][13])
- **RQ3.** What are the **triage gains** vs. baselines (degree, PageRank, volume heuristics) under attacker noise/chaff?

### 5.2 Data & Graph Construction (Cybersecurity focus)

- **Sources.** Windows authentication (Kerberos/NTLM), domain controller logs, Linux auth, **NetFlow**, DNS, EDR/Sysmon, cloud audit.
- **Nodes & edges.**

  - **Nodes:** {host, account, process, IP, DNS name}.
  - **Edges:** time‑stamped {logon, remote exec, network flow, process spawn, name resolution}.
  - **Layers:** build multiplex graph; optionally contract to **auth graph** (account→host) and **host graph** (host→host).

- **Temporalization.** Sliding windows $W$ (e.g., 1h/4h/24h) with **event order** to build **time‑respecting** edges. ([Physical Review Journals][7])
- **Datasets for benchmarking.**

  - **LANL “Comprehensive, Multi‑Source” (58 days, red‑team events)** for labeled evaluation. ([OSTI][11])
  - **LANL “Unified Host & Network” (≈90 days)** for scale tests. ([ar5iv][14])

### 5.3 Algorithms to implement & compare

**(A) Path & Flow Control**

- **Betweenness centrality** (Brandes exact; **GPU/parallel** variants). Complexity \~ $O(|V||E|)$. ([Taylor & Francis Online][1])
- **Approximate betweenness**: **KADABRA** (adaptive shortest‑path sampling; $\epsilon,\delta$ bounds); **ABRA** (Rademacher averages). Use for graphs >10^6 edges. ([arXiv][10])
- **Current‑flow / random‑walk betweenness**: via **Laplacian** linear solves or randomized schemes. (NetworkX/graph‑tool; or STACS’05 algorithms). ([kops.uni-konstanz.de][2])

**(B) Bridges & Community Interfaces**

- **Bridging centrality (BC) & localized BC (LBC)**: $BC(v)=\text{betw}(v)\times \text{bridging\_coeff}(v)$. LBC for distributed/local computation. ([BibSonomy][3])
- **Leverage centrality** to enforce _low‑degree vs. high‑degree neighbors_ asymmetry. ([PubMed][15])

**(C) Core/Periphery & Cohesive Subgraphs**

- **k‑core** ($O(|E|)$); **k‑truss** (polynomial; scalable implementations in practice). Grey cardinals: **low core/truss** yet high A & B scores. ([arXiv][4])

**(D) Cuts, Dominators, Disjoint Paths**

- **Articulation points/bridges** (Tarjan DFS). ([ACM Digital Library][5])
- **s‑t min‑cut / vertex‑cut likelihood**: edge‑cuts via **Dinic/Push‑Relabel**; vertex cuts by **node‑splitting**; summarize **cut‑frequency** across attacker/target seed sets. (Flow & disjoint path modeling per standard text.) &#x20;
- **Dominators** on directed reachability DAGs built from **time‑respecting** edges (start nodes = initial footholds). Compute **idom** sets (Lengauer–Tarjan). ([Princeton University][6])

**(E) Temporal Influence**

- **Temporal betweenness** on “foremost”/“fastest” paths; **ONBRA**/**KDD’20** formulations for scalable estimation. Track **Δ‑scores** per window. ([ACM Digital Library][13])

**(F) Graph Anomaly & Lateral Movement Baselines**

- **OddBall** egonet rules (outlier detection). ([kilthub.cmu.edu][16])
- **Auth graph link prediction** (e.g., **Euler**, **AGE**) as complementary anomaly detectors. ([ACM Digital Library][17])

### 5.4 Composite **Grey Cardinal Score (GCS)**

Let each window $W_t$ produce features for node $v$:

$$
\mathrm{GCS}_t(v) = w_1\,\widehat{BC}_t(v)+ w_2\,CFB_t(v)+ w_3\,Bridg_t(v)+ w_4\,\text{AP}_t(v)+ w_5\,Dom_t(v) + w_6\,\Delta\!TB_t(v) + w_7\,CI_t(v) - w_8\,Core_t(v) - w_9\,Truss_t(v) + w_{10}\,Lev_t(v)
$$

Where:

- $\widehat{BC}$ = (approx.) betweenness (Brandes/KADABRA);
- $CFB$ = current‑flow betweenness;
- $Bridg$ = (localized) bridging centrality;
- $AP$ = articulation/cut membership probability (e.g., fraction of s‑t pairs where $v$ lies on a minimum vertex/edge cut);
- $Dom$ = dominator coverage fraction over attacker→target **time‑respecting** paths;
- $\Delta TB$ = temporal betweenness surge vs. baseline;
- $CI$ = collective‑influence score (optimal percolation control);
- $Core,Truss$ = normalized k‑core/k‑truss indices (penalties);
- $Lev$ = leverage centrality (reward if **neighbors have higher degree**).
  Weights $w_i$ set by **logistic regression** against labels (red‑team events) or **rank aggregation** if unlabeled. ([arXiv][10])

**Implementation notes (scaling & accuracy):**

- Use **KADABRA** with $\epsilon\in[0.01,0.05],\delta=0.01$; **ABRA** for dynamic graphs; **GPU Brandes** if needed. ([arXiv][10])
- For **vertex‑cut likelihood**, sample seed pairs $(s,t)$ from (suspected footholds, high‑value assets) and compute min‑cut after **node‑splitting** (capacity=1) to count membership frequency. (Flow/cut primitives as in standard algorithm texts.) &#x20;
- **Dominator trees:** construct per attack source set; aggregate **idom coverage** per node. ([Princeton University][6])
- **Temporal betweenness:** compute on **foremost paths** per window; use approximations (sampling). ([ACM Digital Library][13])

### 5.5 Outputs & Explainability

- Top‑$k$ **grey cardinal candidates** with **rationales**: dominating s‑t pairs, example time‑respecting paths, critical cuts, Δ‑scores.
- **Counterfactuals**: recompute reachability/shortest distances with candidate removed (_vitality_).
- **Hunt playbooks**: e.g., for host H: show inbound creds, lateral tools (T1550/T1021/T1570), and supporting event IDs. ([center-for-threat-informed-defense.github.io][18])

### 5.6 Evaluation & Metrics

- **Detection**: AUROC/PR for pivot labels (red‑team), precision\@k for triage.
- **Operational value**: reduction in analyst search space vs. baselines (degree, PageRank).
- **Stability**: Kendall‑$\tau$ of rankings across windows; variance under edge noise (dropout).
- **Ablations**: remove feature families (A–F) to quantify contribution.

---

## 6) Pseudocode (sketch)

```python
# Grey Cardinal Analysis (one time window W_t)
# Inputs: temporal/multilayer graph G_t, seed sets S_attackers, T_targets
# Outputs: GCS_t[v] for all v, with explanations

# 1) Core structural measures (approx where needed)
BC  = kadabra_betweenness(G_t, eps=0.02, delta=0.01)            # KADABRA
CFB = current_flow_betweenness(G_t)                              # Laplacian solves
LEV = leverage_centrality(G_t)
CORE= k_core_index(G_t)                                          # Batagelj–Zaversnik
TRUS= k_truss_index(G_t)                                         # Wang–Cheng
BRI = localized_bridging_centrality(G_t)                         # Nanda–Kotz

# 2) Cut & dominators
APfreq = vertex_cut_membership_frequency(G_t, S_attackers, T_targets) # node-splitting + min-cuts
DOM    = dominator_coverage(G_t, S_attackers)                         # Lengauer–Tarjan on TR-DAG

# 3) Temporal betweenness
TB     = temporal_betweenness_foremost(G_t)                      # time-respecting paths
DeltaTB= TB - baseline_smoother(TB_history)

# 4) Collective influence (optional)
CI = collective_influence(G_t, radius=2)

# 5) Score
for v in G_t.nodes():
    GCS_t[v] = (w1*BC[v] + w2*CFB[v] + w3*BRI[v] + w4*APfreq[v] +
                w5*DOM[v] + w6*DeltaTB[v] + w7*CI[v] - w8*CORE[v] -
                w9*TRUS[v] + w10*LEV[v])
return rank_desc(GCS_t)
```

Algorithmic primitives for flow/cuts, disjoint paths, and push‑relabel are textbook standard. &#x20;

---

## 7) Cybersecurity Application Patterns

**Use‑case 1 — Pivot host detection.** Build **host↔host** temporal graphs from auth and remote‑exec events; grey cardinals highlight **quiet bridges** between business units or enclaves. Validate against lateral‑movement ground truth (red‑team). ([USENIX][9])

**Use‑case 2 — Stepping‑stone chains (encrypted).** Use **traffic timing/ON‑OFF thumbprints** to correlate **incoming↔outgoing** sessions; nodes flagged by stepping‑stone detectors that also score highly on **GCS** are **high‑risk pivots**. ([USENIX][19])

**Use‑case 3 — AD privilege paths.** Combine BloodHound relationship graph; identify **non‑obvious brokers** (service accounts, jump boxes) with high **bridging/flow** but low degree. Drive **attack‑path reduction** remediation. ([GitHub][20])

**Use‑case 4 — Cloud lateral movement.** Apply to **IAM principals ↔ resources** graphs; emphasize **dominator** and **vertex‑cut** features between _entry points_ and _crown jewels_.

---

## 8) Open Questions & Research Gaps

- **Temporal betweenness at scale.** Need consistent, **approximate** methods with quantifiable error bars in enterprise‑scale temporal graphs. ([ACM Digital Library][13])
- **Heterogeneous fusion.** Best way to fuse **multi‑layer** (auth, process, NetFlow, DNS) without overweighting noisy edges.
- **Adversarial obfuscation.** Robustness of **GCS** when attackers **pad degree** or **add decoy edges**.
- **Actionability vs. sensitivity.** Balancing high‑recall pivot alerts with operational false positives (e.g., legitimate bastions).

---

## 9) Governance, Safety & Ethics

- **PII minimization:** hash/anonymize identities; role‑based access to raw logs.
- **Explainability:** provide **paths & cuts** as evidence, not just scores (supports analyst trust).
- **No regulated advice:** this is a research methodology, not IR or legal guidance.

---

## 10) Deliverables

1. **Reproducible code** (Python/Julia + NetworkX/igraph/graph‑tool; optional CUDA).
2. **GCS dashboards**: top‑k nodes, evidence paths/cuts, time‑series.
3. **Benchmark report**: metrics vs. baselines; ablations; sensitivity.
4. **Hardening guidance**: segmentation or control changes targeting top grey cardinals (e.g., firewall rules, JIT access).
5. **Appendix**: parameter settings; sampling/error guarantees (KADABRA/ABRA).

---

## 11) References (IEEE style; includes URL/DOI + Accessed)

- U. Brandes, “A Faster Algorithm for Betweenness Centrality,” _J. Math. Sociol._, vol. 25, no. 2, pp. 163–177, 2001. DOI:10.1080/0022250X.2001.9990249. Accessed 2025‑09‑18. ([Taylor & Francis Online][1])
- U. Brandes and D. Fleischer, “Centrality Measures Based on Current Flow,” _STACS_, LNCS 3404, 2005. DOI:10.1007/978-3-540-31856-9_44. Accessed 2025‑09‑18. ([kops.uni-konstanz.de][2])
- M. E. J. Newman, “A measure of betweenness centrality based on random walks,” _Social Networks_, 27(1), 39–54, 2005. DOI:10.1016/j.socnet.2004.11.009. Accessed 2025‑09‑18. ([ScienceDirect][21])
- W. Hwang, T. Kim, M. Ramanathan, A. Zhang, “Bridging Centrality,” _KDD’08_, pp. 336–344, 2008. DOI:10.1145/1401890.1401934. Accessed 2025‑09‑18. ([BibSonomy][3])
- V. Batagelj and M. Zaversnik, “An O(m) Algorithm for Cores Decomposition,” _arXiv\:cs/0310049_, 2003. DOI:10.48550/arXiv.cs/0310049. Accessed 2025‑09‑18. ([arXiv][4])
- J. Wang and J. Cheng, “Truss Decomposition in Massive Networks,” arXiv:1205.6693, 2012 (VLDB’12). DOI:10.48550/arXiv.1205.6693. Accessed 2025‑09‑18. ([ADS][12])
- R. E. Tarjan, “Depth-First Search and Linear Graph Algorithms,” _SIAM J. Comput._, 1(2), 1972. DOI:10.1137/0201010. Accessed 2025‑09‑18. ([ACM Digital Library][5])
- T. Lengauer and R. E. Tarjan, “A Fast Algorithm for Finding Dominators in a Flowgraph,” _ACM TOPLAS_, 1(1), 1979. DOI:10.1145/357062.357071. Accessed 2025‑09‑18. ([Princeton University][6])
- M. Borassi and E. Natale, “KADABRA…,” _ACM JEA_, 24(1), 2019. DOI:10.1145/3284359. Accessed 2025‑09‑18. ([ACM Digital Library][22])
- M. Riondato and E. M. Kornaropoulos, “Fast approximation of betweenness centrality through sampling,” _DMKD_, 30, 438–475, 2016. DOI:10.1007/s10618-015-0423-0. Accessed 2025‑09‑18. ([SpringerLink][23])
- J. Tang et al., “Small‑world behavior in time‑varying graphs,” _Phys. Rev. E_, 81, 055101, 2010. DOI:10.1103/PhysRevE.81.055101. Accessed 2025‑09‑18. ([Physical Review Journals][7])
- S. Buß et al., “Algorithmic Aspects of Temporal Betweenness,” _KDD’20_, 2020. DOI:10.1145/3394486.3403259. Accessed 2025‑09‑18. ([ACM Digital Library][13])
- Y. Zhang and V. Paxson, “Detecting Stepping Stones,” _USENIX Security 2000_. URL: usenix.org. Accessed 2025‑09‑18. ([USENIX][19])
- B. Bowman et al., “Detecting Lateral Movement… with Unsupervised Graph AI,” _RAID 2020_. URL: usenix.org. Accessed 2025‑09‑18. ([USENIX][9])
- **MITRE ATT\&CK** — Lateral Movement (TA0008). URL: attack.mitre.org. Accessed 2025‑09‑18. ([MITRE ATT\&CK][8])
- A. D. Kent, “Comprehensive, Multi‑Source Cyber‑Security Events Data Set,” OSTI, 2015. DOI:10.17021/1179829. Accessed 2025‑09‑18. ([OSTI][11])
- M. Turcotte, A. Kent, C. Hash, “Unified Host and Network Data Set,” 2017. arXiv:1708.07518. Accessed 2025‑09‑18. ([ar5iv][14])

**Textbook (used for algorithmic primitives):**

- _Algorithm Design_ — Network flow, disjoint paths, bipartite matching, push‑relabel, cuts. (Use for proofs/complexity and standard constructions). &#x20;

---

### (Optional) Appendix — Evidence & Implementation Aids

**A.1 Feature‑to‑metric mapping table (excerpt)**

| Phenomenon          | Metric(s)                                   | Why                                                               |
| ------------------- | ------------------------------------------- | ----------------------------------------------------------------- |
| Hidden broker       | betweenness (Brandes/KADABRA), current‑flow | High path control with low degree. ([Taylor & Francis Online][1]) |
| Inter‑module bridge | bridging centrality, LBC                    | Cross‑community connectors. ([BibSonomy][3])                      |
| Choke‑point         | articulation/cut, dominators                | Disrupt reachability if removed. ([ACM Digital Library][5])       |
| Low apparent status | low k‑core/k‑truss, negative leverage       | “Quiet” periphery nodes. ([arXiv][4])                             |
| Ephemeral pivot     | temporal betweenness surge                  | On‑demand movement. ([ACM Digital Library][13])                   |

**A.2 Baselines to beat**: degree, PageRank, volume heuristics; graph‑embedding link predictors (Euler/AGE). ([ACM Digital Library][17])

---

### Quick Start (for an engineering team)

1. **Ingest** LANL 2015 dataset; build **account→host** and **host→host** graphs per hour. ([OSTI][11])
2. **Compute** $\widehat{BC}$ with **KADABRA** ($\epsilon=0.02,\delta=0.01$); **CFB**, **k‑core**, **LBC**, **APfreq** over attacker→target pairs. ([arXiv][10])
3. **Temporal betweenness** (foremost) and **Δ** vs. 7‑day baseline. ([ACM Digital Library][13])
4. **Fit weights** via logistic regression on red‑team labels; output **top‑k** candidates with **evidence paths/cuts**.
5. **Compare** to degree/PageRank; report **precision\@20** and **triage reduction**.

---

If you want, I can also supply a **ready‑to‑run notebook skeleton** (data loaders, feature extractors, KADABRA wrapper, and reporting templates) aligned with this prompt.

[1]: https://www.tandfonline.com/doi/abs/10.1080/0022250X.2001.9990249?utm_source=chatgpt.com 'A faster algorithm for betweenness centrality* : The Journal of Mathematical Sociology: Vol 25, No 2'
[2]: https://kops.uni-konstanz.de/handle/123456789/5680?utm_source=chatgpt.com 'Centrality Measures Based on Current Flow'
[3]: https://www.bibsonomy.org/bibtex/9791703915b3b6907c91d890f6958eb7?utm_source=chatgpt.com 'Bridging centrality: graph mining from element level to group level | BibSonomy'
[4]: https://arxiv.org/abs/cs/0310049?utm_source=chatgpt.com '[cs/0310049] An O(m) Algorithm for Cores Decomposition of Networks'
[5]: https://dl.acm.org/doi/abs/10.1137/0201010?utm_source=chatgpt.com 'Depth-First Search and Linear Graph Algorithms | SIAM Journal on Computing'
[6]: https://collaborate.princeton.edu/en/publications/a-fast-algorithm-for-finding-dominators-in-a-flowgraph?utm_source=chatgpt.com 'A Fast Algorithm for Finding Dominators in a Flowgraph - Princeton University'
[7]: https://journals.aps.org/pre/abstract/10.1103/PhysRevE.81.055101?utm_source=chatgpt.com 'Small-world behavior in time-varying graphs | Phys. Rev. E'
[8]: https://attack.mitre.org/tactics/TA0033/?utm_source=chatgpt.com 'Lateral Movement, Tactic TA0033 - Mobile | MITRE ATT&CK®'
[9]: https://www.usenix.org/conference/raid2020/presentation/bowman?utm_source=chatgpt.com 'Detecting Lateral Movement in Enterprise Computer Networks with Unsupervised Graph AI | USENIX'
[10]: https://arxiv.org/abs/1604.08553?utm_source=chatgpt.com '[1604.08553] KADABRA is an ADaptive Algorithm for Betweenness via Random Approximation'
[11]: https://www.osti.gov/biblio/1179829?utm_source=chatgpt.com 'Comprehensive, Multi-Source Cyber-Security Events Data Set (Dataset) | OSTI.GOV'
[12]: https://ui.adsabs.harvard.edu/abs/2012arXiv1205.6693W/abstract?utm_source=chatgpt.com 'Truss Decomposition in Massive Networks - ADS'
[13]: https://dl.acm.org/doi/10.1145/3394486.3403259?utm_source=chatgpt.com 'Algorithmic Aspects of Temporal Betweenness | Proceedings of the 26th ACM SIGKDD International Conference on Knowledge Discovery & Data Mining'
[14]: https://ar5iv.labs.arxiv.org/html/1708.07518?utm_source=chatgpt.com '[1708.07518] Unified Host and Network Data Set'
[15]: https://pubmed.ncbi.nlm.nih.gov/20808943/?utm_source=chatgpt.com 'A new measure of centrality for brain networks - PubMed'
[16]: https://kilthub.cmu.edu/articles/journal_contribution/OddBall_Spotting_Anomalies_in_Weighted_Graphs/6607802?utm_source=chatgpt.com 'OddBall: Spotting Anomalies in Weighted Graphs'
[17]: https://dl.acm.org/doi/full/10.1145/3588771?utm_source=chatgpt.com 'Euler: Detecting Network Lateral Movement via Scalable Temporal Link Prediction | ACM Transactions on Privacy and Security'
[18]: https://center-for-threat-informed-defense.github.io/mappings-explorer/attack/attack-10.1/domain-enterprise/tactics/TA0008/?utm_source=chatgpt.com 'ATT&CK Tactic TA0008 - Mappings Explorer'
[19]: https://www.usenix.org/conference/9th-usenix-security-symposium/detecting-stepping-stones?utm_source=chatgpt.com 'Detecting Stepping Stones | USENIX'
[20]: https://github.com/gold1029/BloodHound?utm_source=chatgpt.com 'GitHub - gold1029/BloodHound: BloodHound uses graph theory to reveal the hidden and often unintended relationships within an Active Directory environment'
[21]: https://www.sciencedirect.com/science/article/abs/pii/S0378873304000681?utm_source=chatgpt.com 'A measure of betweenness centrality based on random walks - ScienceDirect'
[22]: https://dl.acm.org/doi/abs/10.1145/3284359?utm_source=chatgpt.com 'KADABRA is an ADaptive Algorithm for Betweenness via Random Approximation | ACM Journal of Experimental Algorithmics'
[23]: https://link.springer.com/article/10.1007/s10618-015-0423-0?utm_source=chatgpt.com 'Fast approximation of betweenness centrality through sampling | Data Mining and Knowledge Discovery'
