# docs/adr/0021-branch-prediction.md (Phase E4). A tight 5-iteration
# backward-branch loop, deliberately small enough that one program exercises
# every interesting BHT/BTB state transition: iteration 1 (cold BHT+BTB
# miss, mispredict), iteration 2 (BHT now weakly-taken [01->10 requires two
# "taken" trainings], STILL mispredicts once more since predict_taken is the
# counter's MSB), iterations 3-4 (BHT strongly/weakly-taken and BTB has a
# valid target from iteration 1's own training -- correctly predicted,
# should cost zero bubble cycles), iteration 5 (BHT still predicts taken,
# but the loop actually exits this time -- a real "predicted taken, actually
# not taken" misprediction, recovered via the fall-through path). x10 must
# end at exactly 5 regardless -- misprediction never changes architectural
# results, only timing.
addi  x1, x0, 5      # 0: loop counter
addi  x10, x0, 0     # 4: accumulator
loop:
addi  x10, x10, 1    # 8
addi  x1, x1, -1     # 12
bne   x1, x0, loop   # 16
addi  x11, x0, 777   # 20: proves the loop exited via correct fall-through, not a skipped/duplicated iteration

fence
halt:
jal   x0, halt       # 24: spin here forever
