

[ Start ]
           |
           v
+------------------------------------------------------+
| Load data; define scheduling tasks and legal         |
| placement options.                                   |
+------------------------------------------------------+
           |
           v
+------------------------------------------------------+
| Initialize N individuals.                            |
| Each chromosome has one placement preference         |
| per task: day, start time, room, plus task priority. |
+------------------------------------------------------+
           |
           v
+------------------------------------------------------+ <--- (Loop Start)
| For each chromosome, call                            |
| r_scheduler_export_helpers with its preferences.     |
| Helper constructs a complete schedule, using         |
| alternatives to resolve conflicts.                   |
+------------------------------------------------------+
           |
           v
+------------------------------------------------------+
| Validate constructed schedule against the agreed     |
| zero-violation rule set.                             |
+------------------------------------------------------+
           |
           v
  < Zero violations? >
     /            \
  (Yes)           (No)
   |                |
   |                v
   |      +------------------------------------------------+
   |      | Helper retries construction/repair with        |
   |      | remaining legal placements and new tie-breaks. |
   |      +------------------------------------------------+
   |                |
   |                v
   |           [ Validate ]
   |                |
   +--------+-------+
            |
            v
+------------------------------------------------------+
| Score the helper-built schedule. Fitness uses that   |
| same schedule, including coverage, constraints, and  |
| preference satisfaction.                             |
+------------------------------------------------------+
            |
            v
  < Generation limit reached? >
     /            \
  (Yes)           (No)
   |                |
   v                v
+------------------+  +-----------------------------------------------+
| Return highest   |  | Keep elite schedules and their chromosomes.   |
| fitness verified |  +-----------------------------------------------+
| schedule.        |                          |
+------------------+                          v
   |                  +-----------------------------------------------+
 [ End ]              | Select parent chromosomes using fitness.      |
                      +-----------------------------------------------+
                                              |
                                              v
                      +-----------------------------------------------+
                      | Crossover task-level placement preferences.   |
                      | Inherit each task’s preference from a parent. |
                      +-----------------------------------------------+
                                              |
                                              v
                      +-----------------------------------------------+
                      | Mutate selected task preferences by choosing  |
                      | another legal candidate placement for that    |
                      | same task.                                    |
                      +-----------------------------------------------+
                                              |
                                              v
                      +-----------------------------------------------+
                      | Call r_scheduler_export_helpers for each      |
                      | offspring. It constructs/repairs the schedule |
                      | from the inherited and mutated preferences.   |
                      +-----------------------------------------------+
                                              |
                                              +-----------------------+
                                                                      |
                                                                      v
                                                        (Back to Loop Start)
