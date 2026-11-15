# Modeling decisions

Rushlane models a single canteen day as a discrete-event simulation. This file
records the modeling choices, why they were made, and how to measure the inputs
in the field.

## Arrivals

Arrivals follow a nonhomogeneous Poisson process with a piecewise-constant
rate: one rate per `bin_minutes` bin, applied per bin independently. This is a
standard way to model time-varying arrival intensity without estimating a full
rate function from sparse data.

- The per-bin generator draws `Poisson(lambda_bin * bin_hours)` arrivals, placed
  uniformly inside the bin.
- `scale` multiplies all rates at once (use 1.2 for exam weeks).
- With a constant rate in every bin the process is exactly homogeneous Poisson,
  which is what the Erlang C validation relies on.

### Field measurement

1. For at least five days, count customers entering per 15-minute bin from
   opening to closing.
2. Average each bin across days, convert to per hour, and write the numbers
   into `rates_per_hour` from the opening bin onwards.
3. Set `scale` for known rush factors (end-of-semester, exam weeks).

## Service times

Service times are drawn independently per customer. Parameters are derived from
the configured mean and coefficient of variation (`cv`):

- `exponential`: rate `1 / mean` (cv forced to 1)
- `lognormal`: `sigma^2 = log(1 + cv^2)`, `mu = log(mean) - sigma^2 / 2`
- `gamma`: shape `1 / cv^2`, scale `mean * cv^2`
- `normal`: `sd = cv * mean`, truncated at 0.5 s
- `constant`: exactly `mean`

### Field measurement

1. Stopwatch at least 100 orders per service type.
2. Compute the mean and the standard deviation, derive `cv = sd / mean`.
3. Choose the distribution by shape: lognormal for "mostly fast, occasionally
   slow", gamma for "similar but capped on the fast side", exponential when in
   doubt.

## Queue discipline and customer behavior

- FIFO in every lane. No jockeying (switching lanes) in v0.1.
- `single`: one shared line, any free cashier serves from it.
- `per_server`: one line per cashier. New customers join the shortest line
  (fewest waiting customers) whose server is on and not leaving.
- Balking: a customer refuses to join when the line they would join already has
  `balk_queue_length` or more waiting customers. Set to 0 to disable.
- Reneging: waiting customers carry an exponential patience timer (mean
  `patience_mean_minutes`). When it expires while they still wait, they leave
  and count as abandoned. Patience is only consumed while waiting, not while in
  service. Set to 0 to disable.

## Staffing and shifts

`[servers] count` sets a constant staffing level. `[[shifts]]` entries override
it in their windows; outside all windows the constant applies. Reducing
capacity mid-day marks the excess cashiers as leaving: they finish their
current customer, then switch off; waiting customers in a closed line are
redistributed to the remaining lines.

## Replication and randomness

- Replication `i` uses `StableRNG(seed + i)`. Scenarios compared across cashier
  counts at the same `i` share the arrival stream and service-time stream
  (common random numbers), so differences are systematic, not noise.
- Note: balking and reneging paths can diverge between scenarios once customer
  fates differ, so CRN pairs the draws, not the exact outcomes.
- Every reported mean carries a 95% t-based confidence interval.

## Metrics

- Waiting time is queueing delay (entry minus arrival). Only customers who
  completed service before closing are counted. Customers still waiting or
  mid-service at closing are excluded.
- Queue length is the number waiting (not in service), time-weighted over the
  day for the average and peaked for the maximum.
- Utilization is busy seconds divided by scheduled cashier-seconds (shifts
  respected).
- Abandoned percent is `(balked + reneged) / arrivals * 100`.
- Throughput is served customers per hour.

## Cost model

For cashier count `c`, per day:

- cashier cost: `cashier_per_hour * c * day_hours`
- lost sales cost: `lost_customer_cost * expected_arrivals * abandon_rate`

The optimizer reports the smallest `c` meeting the SLA (P90 wait and abandon
rate) as the recommendation, plus the cheapest `c` by total cost for comparison.

## Validation

In steady state (constant rate, exponential service, no balking/reneging) the
engine must reproduce Erlang C. The test suite checks the simulation mean wait
against the analytic `Wq` within 3% on a fixed seed.

## Known limits

- No jockeying, no priority customers, no cashier learning curves.
- Rates are piecewise constant per bin; within a bin, arrivals are uniform.
- The day horizon ends at closing; there is no carry-over to the next day.
