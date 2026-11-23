# Found with Haze

Haze models of open-source libraries where the code and the docs disagree. Each finding was
reproduced on the library's latest release before it was reported upstream. Every model lists, in
its opening comment, the source lines it describes. When the fix belongs in the code rather than
the docs, the model includes it too, and with it the checks pass.

| model | library | what doesn't hold | report |
|---|---|---|---|
| [bloom_filters.hz](bloom_filters.hz) | [bloom-filters](https://github.com/Callidon/bloom-filters) 3.0.4 | `PartitionedBloomFilter` can't reach error rates below about 0.5/n | [bloom-filters#133](https://github.com/Callidon/bloom-filters/issues/133) |
| [failsafe_go.hz](failsafe_go.hz) | [failsafe-go](https://github.com/failsafe-go/failsafe-go) 0.9.8 | half-open frees permits for, and counts results of, calls it didn't admit | [failsafe-go#148](https://github.com/failsafe-go/failsafe-go/issues/148) |
| [resilience4j.hz](resilience4j.hz) | [resilience4j](https://github.com/resilience4j/resilience4j) 2.4.0 | an ignored exception from a call permitted while CLOSED adds a HALF_OPEN permit | [resilience4j#2602](https://github.com/resilience4j/resilience4j/issues/2602) |
| [pybreaker.hz](pybreaker.hz) | [pybreaker](https://github.com/danielfm/pybreaker) 1.4.1 | `calling()` lets several trials through in half-open and can close after a failed trial | [pybreaker#113](https://github.com/danielfm/pybreaker/issues/113) |
| [node_retry.hz](node_retry.hz) | [retry](https://github.com/tim-kos/node-retry) 0.13.1 | attempts start after `maxRetryTime`; with `randomize`, retry *i* doesn't follow the documented formula | [node-retry#102](https://github.com/tim-kos/node-retry/issues/102), [#103](https://github.com/tim-kos/node-retry/issues/103) |
| [go_retry.hz](go_retry.hz) | [go-retry](https://github.com/sethvargo/go-retry) 0.5.0 | `NewFibonacci` waits 1, 2, 3, 5, not 1, 1, 2, 3 as documented | [go-retry#54](https://github.com/sethvargo/go-retry/issues/54) |
