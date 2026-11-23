# Found with Haze

Models of open-source libraries whose behavior didn't match their documentation. Each one was
written while checking the library's promises, and each finding was reproduced on the library's
latest release before it was reported. The header of every model cites the lines of code it
stands for, and every model includes the suggested fix, so you can see the claims hold once it's
in.

| model | library | what doesn't hold | report |
|---|---|---|---|
| [bloom_filters.hz](bloom_filters.hz) | [bloom-filters](https://github.com/Callidon/bloom-filters) 3.0.4 | `PartitionedBloomFilter` can't reach error rates below about 0.5/n | pending |
| [failsafe_go.hz](failsafe_go.hz) | [failsafe-go](https://github.com/failsafe-go/failsafe-go) 0.9.8 | half-open frees permits for, and counts results of, calls it didn't admit | pending |
| [resilience4j.hz](resilience4j.hz) | [resilience4j](https://github.com/resilience4j/resilience4j) 2.4.0 | an ignored exception from a call permitted while CLOSED adds a HALF_OPEN permit | pending |
| [pybreaker.hz](pybreaker.hz) | [pybreaker](https://github.com/danielfm/pybreaker) 1.4.1 | `calling()` lets several trials through in half-open and can close after a failed trial | pending |
| [node_retry.hz](node_retry.hz) | [retry](https://github.com/tim-kos/node-retry) 0.13.1 | attempts start after `maxRetryTime`; with `randomize`, retry *i* doesn't follow the documented formula | pending |
| [go_retry.hz](go_retry.hz) | [go-retry](https://github.com/sethvargo/go-retry) 0.5.0 | `NewFibonacci` waits 1, 2, 3, 5, not 1, 1, 2, 3 as documented | pending |

The write-ups are on the [Haze blog](https://haze-lang.pages.dev/blog/).
