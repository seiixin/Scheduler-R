[ Start ]
           |
           v
+------------------------------------------------------+
| Load scheduling data; build candidate placement      |
| nodes and compatibility graph.                       |
+------------------------------------------------------+
           |
           v
+------------------------------------------------------+
| Compute heuristic eta for candidate placements;      |
| initialize pheromone tau.                            |
+------------------------------------------------------+
           |
           v
+------------------------------------------------------+ <---+
| Begin ACO iteration.                                 |     |
| Reset iteration's best valid schedule.               |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
+------------------------------------------------------+     |
| Begin ant construction.                              |     |
| Start with an empty set of task placement            |     |
| preferences and a fresh graph state.                 |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
+------------------------------------------------------+     |
| Select candidate placement decisions using           |     |
| P(i) proportional to tau(i)^alpha * eta(i)^beta.     |     |
| Use only active, compatible candidate nodes.         |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
+------------------------------------------------------+     |
| Convert the ant's candidate node decisions and       |     |
| ranked alternatives into task-keyed preferences      |     |
| (offering/meeting -> day, time, room).               |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
+------------------------------------------------------+     |
| Call r_scheduler_export_helpers inside this ant      |     |
| loop with the task preferences.                      |     |
| Helper constructs a complete schedule, trying the    |     |
| preferred placements first and repairing conflicts   |     |
| with other legal placements.                         |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
+------------------------------------------------------+     |
| Validate the helper-built schedule using the agreed  |     |
| zero-violation rule set.                             |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
            < Zero violations? >                             |
              /            \                                 |
           (Yes)           (No)                              |
             |               |                               |
             |               v                               |
             |     +-----------------------------------+     |
             |     | Helper retries/reconstructs using |     |
             |     | the next ranked legal placements. |     |
             |     +-----------------------------------+     |
             |               |                               |
             |               +------------+                  |
             v                            |                  |
+--------------------------------------+  |                  |
| Score this finalized schedule.       |  |                  |
| Fitness reflects the helper-built    |  |                  |
| schedule, not the ant's partial      |  |                  |
| graph construction.                  |  |                  |
+--------------------------------------+  |                  |
           |                              |                  |
           v                              v                  |
+------------------------------------------------------+     |
| Map final schedule placements back to candidate      |     |
| node IDs. Keep only exact matches for pheromone      |     |
| reinforcement; repaired placements drive deposits,   |     |
| not rejected pre-repair choices.                     |     |
+------------------------------------------------------+     |
           |                                                 |
           v                                                 |
     < Better valid schedule for this iteration? >           |
              /            \                                 |
           (Yes)           (No)                              |
             |               |                               |
             v               |                               |
+------------------------------+                             |
| Save as iteration best       |                             |
| (schedule, fitness, mapped   |                             |
| final node IDs).             |                             |
+------------------------------+                             |
             |               |                               |
             +-------+-------+                               |
                     |                                       |
                     v                                       |
           < More ants this iteration? >                     |
              /            \                                 |
           (Yes)           (No)                              |
             |               |                               |
             |               v                               |
             |     < More ACO iterations? >                  |
             |        /                  \                   |
             |     (Yes)                 (No)                |
             |       |                     |                 |
             |       v                     v                 |
             |  +-------------------+  < Any valid schedule >|
             |  | Evaporate/deposit |     /            \     |
             |  | pheromones on     |  (Yes)          (No)   |
             |  | iteration/global- |   |              |     |
             |  | best schedules.   |   v              v     |
             |  +-------------------+  |     +-----------------+
             |       |                 |     | Report no valid |
             |       |                 |     | schedule found. |
             |       |                 |     +-----------------+
             |       |                 |              |
             |       v                 v              v
             |     +-----------------------------------------+
             |     | Return highest-fitness validated        |
             |     | helper-built schedule.                  |
             |     +-----------------------------------------+
             |                          |                    |
             |                       [ End ]                 |
             |                                               |
             +-----------------------------------------------+ 
                    (Loop back to Construct next ant)