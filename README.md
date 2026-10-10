# Automated Class Scheduling System — Demo Guide

Ito ang quick guide para sa client, panel, o student demonstrator. Ang system ay gumagawa at nagva-validate ng class schedule gamit ang Genetic Algorithm (GA), Ant Colony Optimization (ACO), at Simulated Annealing (SA).

## Demo-ready outputs

| Algorithm | Script | Output file | Sheets |
| --- | --- | --- | --- |
| GA | `ga_scheduler.R` | `outputs/ga_schedule_formatted.xlsx` | `Schedule`, `Constraint_Verification`, `Coverage`, `Unscheduled`, `GA_Metrics` |
| ACO | `aco_scheduler.R` | `outputs/aco_schedule_formatted.xlsx` | `Schedule`, `Constraint_Verification`, `Coverage`, `Unscheduled`, `ACO_Metrics` |
| SA | `sa_scheduler.R` | `outputs/sa_schedule_formatted.xlsx` | `Schedule`, `Constraint_Verification`, `Coverage`, `Unscheduled`, `SA_Metrics` |
| Comparison | `08_main_execution.R` | `outputs/run_log_*.txt`, `trials_summary_*.csv`, plots | — |

---

## Algorithm Parameters — Quick Reference

Lahat ng parameters ay optional. Kung hindi i-set, gagamitin ang mga default value. I-set ang `$env` variable sa PowerShell **bago** i-run ang script, o i-clear pagkatapos ng run gamit ang `Remove-Item Env:R_UPC_*`.

### Genetic Algorithm (GA)

| Environment Variable | Paliwanag | Range | Default |
|---|---|---|---|
| `R_UPC_GA_POP` | Population size | integer ≥ 1 | `8` |
| `R_UPC_GA_GENERATIONS` | Number of generations | integer ≥ 1 | `4` |
| `R_UPC_GA_CROSSOVER` | Crossover rate | 0.0 – 1.0 | `0.88` |
| `R_UPC_GA_MUTATION` | Mutation rate | 0.0 – 1.0 | `0.18` |
| `R_UPC_GA_ELITISM` | Elitism fraction | 0.0 – 1.0 | `0.12` |
| `R_UPC_GA_TOURNAMENT` | Tournament pool size | integer ≥ 1 | `3` |
| `R_UPC_GA_SEED` | RNG seed | integer | `20260915` |
| `R_UPC_MAX_NODES` | Candidate node cap | integer ≥ 1 | `1050` |
| `R_UPC_MAX_ROOMS` | Rooms sampled per offering | integer ≥ 1 | `1` |
| `R_UPC_MAX_STARTS` | Start slots per day | integer ≥ 1 | `1` |

### Simulated Annealing (SA)

| Environment Variable | Paliwanag | Range | Default |
|---|---|---|---|
| `R_UPC_SA_STEPS` | Total cooling steps | integer ≥ 1 | `5` |
| `R_UPC_SA_ITERATIONS` | Inner iterations per step | integer ≥ 1 | `20` |
| `R_UPC_SA_ALPHA` | Cooling rate (mas malapit sa 1 = mas mabagal) | 0.0 – 1.0 | `0.985` |
| `R_UPC_SA_T0_FACTOR` | Initial temperature multiplier | > 0 | `2` |
| `R_UPC_SA_REHEAT` | Steps between reheats | integer ≥ 1 | `10` |
| `R_UPC_MAX_NODES` | Candidate node cap | integer ≥ 1 | `2500` |
| `R_UPC_MAX_ROOMS` | Rooms sampled per offering | integer ≥ 1 | `2` |
| `R_UPC_MAX_STARTS` | Start slots per day | integer ≥ 1 | `2` |

### Ant Colony Optimization (ACO)

| Environment Variable | Paliwanag | Range | Default |
|---|---|---|---|
| `R_UPC_ACO_ANTS` | Number of ants | integer ≥ 1 | `1` |
| `R_UPC_ACO_ITERATIONS` | Number of iterations | integer ≥ 1 | `1` |
| `R_UPC_ACO_ALPHA` | Pheromone weight | > 0 | `1` |
| `R_UPC_ACO_BETA` | Heuristic weight | > 0 | `2` |
| `R_UPC_ACO_RHO_LOCAL` | Local evaporation rate | 0.0 – 1.0 | `0.1` |
| `R_UPC_ACO_RHO_GLOBAL` | Global evaporation rate | 0.0 – 1.0 | `0.2` |
| `R_UPC_ACO_Q0` | Exploitation probability | 0.0 – 1.0 | `0.9` |
| `R_UPC_ACO_TAU0` | Initial pheromone level | > 0 | `1.0` |
| `R_UPC_MAX_NODES` | Candidate node cap | integer ≥ 1 | `2500` |
| `R_UPC_MAX_ROOMS` | Rooms sampled per offering | integer ≥ 1 | `2` |
| `R_UPC_MAX_STARTS` | Start slots per day | integer ≥ 1 | `2` |

> **Nota sa validation:** Kung ang value ay labas ng valid range (halimbawa `R_UPC_GA_CROSSOVER = "1.5"` para sa 0–1 na parameter), awtomatikong babalik sa default ang script nang walang error.

> **Para i-clear lahat ng env vars pagkatapos ng run:**
> ```powershell
> Get-ChildItem Env: | Where-Object { $_.Name -like "R_UPC_*" } | Remove-Item
> ```

---

### Suggested client demonstration flow

1. Buksan ang napiling Excel output.
2. Sa `Schedule`, i-filter ang `day`, `faculty_id`, `section_id`, o `room_id` para ipakita ang actual class assignments.
3. Buksan ang `Constraint_Verification`. Ang tamang final output ay may **0** sa lahat ng hard constraint rules.
4. Buksan ang `Coverage` at `Unscheduled`. Dapat ang Scheduled ay katumbas ng target meetings at ang Unscheduled ay **0**.
5. Buksan ang `GA_Metrics`, `ACO_Metrics`, o `SA_Metrics` para ipakita ang runtime at final score.

## Paano basahin ang metrics

| Metric | Kahulugan | Target para sa final demo |
| --- | --- | --- |
| Total Computation Time (seconds) | Aktuwal na tagal ng algorithm run | I-report ang eksaktong value sa workbook |
| Final Fitness / Energy Score | Quality/objective value ng algorithm | I-report kasama ng algorithm name |
| Total Scheduled Meetings | Bilang ng naitalagang class meetings | 1,006–1,010 (depende sa valid input patterns) |
| Total Unscheduled Meetings | Meetings na walang room/day/time assignment | 0 |
| Hard Constraint Violations | Kabuuan ng violations sa verification sheet | 0 |

Hindi direktang puwedeng ikumpara ang raw fitness score ng GA, ACO, at SA. Magkakaiba ang formula at scale ng bawat algorithm. Para sa fair presentation, ihambing: **100% coverage**, **0 hard violations**, at **computation time**.

---

## Step-by-Step Execution Guide per Algorithm

### A. Genetic Algorithm (GA) Execution Steps

Ang `ga_scheduler.R` ay ang dedicated GA schedule generator — may parehong structure at output format gaya ng `aco_scheduler.R` at `sa_scheduler.R`. Ito ay nakatuon lang sa pag-generate ng GA schedule; ang trials comparison, statistical tests, at plots ay nasa `08_main_execution.R`.

1. **Ihanda ang Input Data:** Siguraduhing naka-save ang data bilang `files/Scheduling.xlsx` na may kumpletong sheet names (`SectionCourse`, `SectionInfo`, `CourseInfo`, `DeptRoom`, `FacultyInfo`, `FacultyCourse`, `FacultyTime`).
2. **Buksan ang PowerShell:** Pumunta sa project root directory.
3. **Patakbuhin ang GA Script:**
   ```powershell
   & 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla ga_scheduler.R
   ```
4. **Hintayin ang completion:** Ang GA ay gumagamit ng full-permutation chromosome representation — bawat fitness evaluation ay nagre-rebuild ng DynamicGraph para sa lahat ng candidate nodes. Inaasahang runtime sa buong dataset: **5–10 minuto**.
5. **Suriin ang Output:** Buksan ang `outputs/ga_schedule_formatted.xlsx` at i-check ang `Schedule`, `Constraint_Verification`, `Coverage`, `Unscheduled`, at `GA_Metrics` tabs.

**Optional — i-adjust ang search budget at algorithm parameters:**
```powershell
# Search budget
$env:R_UPC_GA_POP         = "50"     # population size        (default: 8)
$env:R_UPC_GA_GENERATIONS = "100"    # generations            (default: 4)
$env:R_UPC_MAX_NODES      = "1050"   # candidate node cap     (default: 1050)
$env:R_UPC_GA_SEED        = "42"     # RNG seed               (default: 20260915)
# Algorithm parameters
$env:R_UPC_GA_CROSSOVER   = "0.85"   # crossover rate 0–1     (default: 0.88)
$env:R_UPC_GA_MUTATION    = "0.20"   # mutation rate 0–1      (default: 0.18)
$env:R_UPC_GA_ELITISM     = "0.10"   # elitism fraction 0–1   (default: 0.12)
$env:R_UPC_GA_TOURNAMENT  = "5"      # tournament pool size   (default: 3)
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla ga_scheduler.R
```

---

### B. Ant Colony Optimization (ACO) Execution Steps

1. **Ihanda ang Input Data:** Siguraduhing tama ang laman ng `files/Scheduling.xlsx`.
2. **Buksan ang PowerShell:** Pumunta sa project root directory.
3. **Patakbuhin ang ACO Script:**
   ```powershell
   & 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla aco_scheduler.R
   ```
4. **Awtomatikong Safety & Verification:** Hayaang dumaan sa safety check ng script para matiyak na 100% ang coverage at zero hard violations bago i-save.
5. **Suriin ang Output:** Buksan ang `outputs/aco_schedule_formatted.xlsx` at i-check ang `Schedule`, `Constraint_Verification`, `Coverage`, `Unscheduled`, at `ACO_Metrics` tabs.

**Optional — i-adjust ang search budget at algorithm parameters:**
```powershell
# Search budget
$env:R_UPC_ACO_ANTS       = "10"     # number of ants                   (default: 1)
$env:R_UPC_ACO_ITERATIONS = "50"     # number of iterations             (default: 1)
$env:R_UPC_MAX_NODES      = "2500"   # candidate node cap               (default: 2500)
# Algorithm parameters
$env:R_UPC_ACO_ALPHA      = "1"      # pheromone weight > 0             (default: 1)
$env:R_UPC_ACO_BETA       = "3"      # heuristic weight > 0             (default: 2)
$env:R_UPC_ACO_RHO_LOCAL  = "0.1"    # local evaporation rate  0–1      (default: 0.1)
$env:R_UPC_ACO_RHO_GLOBAL = "0.15"   # global evaporation rate 0–1      (default: 0.2)
$env:R_UPC_ACO_Q0         = "0.85"   # exploitation probability 0–1     (default: 0.9)
$env:R_UPC_ACO_TAU0       = "1.0"    # initial pheromone level > 0      (default: 1.0)
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla aco_scheduler.R
```

---

### C. Simulated Annealing (SA) Execution Steps

1. **Ihanda ang Input Data:** I-verify na naka-update ang `files/Scheduling.xlsx`.
2. **Buksan ang PowerShell:** Pumunta sa project root directory.
3. **Patakbuhin ang SA Script:**
   ```powershell
   & 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla sa_scheduler.R
   ```
4. **Awtomatikong Safety & Verification:** Hayaang tapusin ng script ang computation at i-validate ang hard constraints.
5. **Suriin ang Output:** Buksan ang `outputs/sa_schedule_formatted.xlsx` at i-check ang `Schedule`, `Constraint_Verification`, `Coverage`, `Unscheduled`, at `SA_Metrics` tabs.

**Optional — i-adjust ang search budget at algorithm parameters:**
```powershell
# Search budget
$env:R_UPC_SA_STEPS       = "300"    # total cooling steps              (default: 20)
$env:R_UPC_SA_ITERATIONS  = "100"    # inner iterations per step        (default: 50)
$env:R_UPC_MAX_NODES      = "2500"   # candidate node cap               (default: 2500)
# Algorithm parameters
$env:R_UPC_SA_ALPHA       = "0.99"   # cooling rate 0–1 (near 1=slower) (default: 0.985)
$env:R_UPC_SA_T0_FACTOR   = "3"      # initial temperature multiplier   (default: 2)
$env:R_UPC_SA_REHEAT      = "50"     # steps between reheats            (default: 10)
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla sa_scheduler.R
```

---

### D. Full Comparative Experiment (GA vs ACO vs SA)

Ang `08_main_execution.R` ay nagpapatakbo ng multiple trials ng lahat ng tatlong algorithms at gumagawa ng statistical comparison outputs. **Hindi na ito gumagawa ng GA Excel workbook** — para sa GA schedule, gamitin ang `ga_scheduler.R`.

```powershell
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla 08_main_execution.R
```

**Mga output files:**
- `outputs/run_log_*.txt` — live log ng lahat ng trials at statistical results
- `outputs/trials_summary_*.csv` — fitness at computation time per trial
- `outputs/descriptive_stats_*.csv` — mean, SD, median, CI95 per algorithm
- `outputs/boxplot_fitness_*.png`, `violin_fitness_*.png`, `barplot_time_*.png`, `scatter_fit_time_*.png`
- `outputs/best_schedule_*.csv` — best schedule across all algorithms
- `outputs/FINAL_RESULTS_*.rds` — complete R results object

Para sa mabilis na smoke test (3 trials, 30 offerings lang):
```powershell
$env:R_UPC_QUICK_TEST = '1'
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla 08_main_execution.R
```

Para i-control ang bilang ng trials sa full mode:
```powershell
$env:R_UPC_N_TRIALS = 10
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla 08_main_execution.R
```

---

## R Packages Setup (First Run Note)

Sa unang run, maaaring mag-install ang R ng required packages (`dplyr`, `tidyr`, `stringr`, `readxl`) sa local `R_libs` folder. Para sa Excel export, kailangan ang `writexl`:

```powershell
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' --vanilla -e ".libPaths(c('R_libs', .libPaths())); install.packages('writexl', repos='https://cloud.r-project.org', lib='R_libs')"
```

Ang lahat ng standalone schedulers (`ga_scheduler.R`, `aco_scheduler.R`, `sa_scheduler.R`) ay may independent safety check. Kapag incomplete ang stochastic result, gagamit sila ng validated constraint-first repair; ang Excel output ay isusulat lamang kapag 100% covered at zero ang lahat ng hard-constraint violations. Makikita ang schedule source sa metrics sheet.

---

## Paggamit ng ibang scheduling workbook

Ang current production source ay `files/Scheduling.xlsx`. Bago magpalit ng input, gumawa muna ng backup sa labas ng project folder.

1. Ihanda ang bagong workbook na may parehong sheet names at columns: `SectionCourse`, `SectionInfo`, `CourseInfo`, `DeptRoom`, `FacultyInfo`, `FacultyCourse`, at `FacultyTime`.
2. Siguraduhing valid ang data types: IDs, enrolment, weekly hours, room counts, at faculty availability ay numeric kung kinakailangan.
3. Palitan ang `files/Scheduling.xlsx` ng bagong validated workbook.
4. Kung may additional section-course pairs, i-update rin ang `files/Section Course Not Included.xlsx`; kung wala, panatilihin itong valid at walang duplicate pairs.
5. Patakbuhin ang algorithm at tingnan muna ang `Constraint_Verification` bago gamitin ang bagong schedule sa presentation.

`files/Data.xlsx` at ang CSV files sa `files/Data-CourseInfo,Data-DeptRoom,Data-FacultyCourse/` ay core supporting data para sa R workflow. Huwag i-delete o palitan ang kanilang column structure nang walang testing.

---

## 11 hard constraints na ipapakita sa panel

1. 100% meeting coverage
2. Walang class na lalampas ng 8:00 PM
3. Department-compatible room assignment
4. Sapat na room capacity
5. Walang room overlap
6. Walang faculty overlap
7. Walang section/student overlap
8. May faculty lunch break mula 10 AM–1 PM
9. May section lunch break mula 10 AM–1 PM
10. Sinusunod ang faculty availability
11. Sinusunod ang faculty workload limit

---

## Important presentation note

Ang lahat ng formatted workbooks ay may sariling metrics worksheet na naglalaman ng computation time at fitness score ng parehong run. Para sa formal algorithm comparison, gamitin ang runtime at score na naka-save sa parehong workbook; huwag ikumpara ang raw scores nang direkta sa magkakaibang algorithms dahil magkakaiba ang formula at scale nila.
