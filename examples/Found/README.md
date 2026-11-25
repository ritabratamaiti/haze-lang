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
| [go_retry.hz](go_retry.hz) | [go-retry](https://github.com/sethvargo/go-retry) 0.5.0 | `NewFibonacci` waits 1, 2, 3, 5, not 1, 1, 2, 3 as documented | [go-retry#54](https://github.com/sethvargo/go-retry/issues/54), fixed in [v0.6.0](https://github.com/sethvargo/go-retry/releases/tag/v0.6.0) |
| [throttled.hz](throttled.hz) | [throttled](https://github.com/throttled/throttled) 2.15.1 | a peek (quantity 0) that loses a compare-and-swap race uses up a unit or reports limited | [throttled#118](https://github.com/throttled/throttled/issues/118) |
| [backon.hz](backon.hz) | [backon](https://github.com/Xuanwo/backon) 1.6.0 | Fibonacci jitter stays below `min_delay` instead of ranging over the current delay | [backon#252](https://github.com/Xuanwo/backon/issues/252) |
| [slog_sampling.hz](slog_sampling.hz) | [slog-sampling](https://github.com/samber/slog-sampling) 1.7.0 | threshold and absolute sampling let more than the limit through when goroutines log a new message at once | [slog-sampling#63](https://github.com/samber/slog-sampling/issues/63) |
| [openfeature_dotnet.hz](openfeature_dotnet.hz) | [OpenFeature flagd provider for .NET](https://github.com/open-feature/dotnet-sdk-contrib) 0.8.2 | fractional weights computed with JsonLogic fail with `PARSE_ERROR` | [dotnet-sdk-contrib#789](https://github.com/open-feature/dotnet-sdk-contrib/issues/789) |
| [openfeature_java.hz](openfeature_java.hz) | [OpenFeature flagd-core for Java](https://github.com/open-feature/java-sdk-contrib) 3.0.0 | an empty targeting key is bucketed instead of falling back to the default variant | [java-sdk-contrib#1991](https://github.com/open-feature/java-sdk-contrib/issues/1991) |
| [unleash_node.hz](unleash_node.hz) | [unleash-client](https://github.com/Unleash/unleash-node-sdk) 6.12.2 | user IDs with non-ASCII characters hash differently than in Edge and the Go and Python SDKs | [unleash-node-sdk#927](https://github.com/Unleash/unleash-node-sdk/issues/927) |
| [dubbo_go_leastactive.hz](dubbo_go_leastactive.hz) | [dubbo-go](https://github.com/apache/dubbo-go) 3.3.2 | `leastactive`'s weighted draw among tied providers is off by one | [dubbo-go#3871](https://github.com/apache/dubbo-go/issues/3871) |
| [pyprobables_cuckoo.hz](pyprobables_cuckoo.hz) | [pyprobables](https://github.com/barrust/pyprobables) 0.7.0 | `CuckooFilter`'s false positive rate grows far above `error_rate` | [pyprobables#154](https://github.com/barrust/pyprobables/issues/154) |
| [aiomisc.hz](aiomisc.hz) | [aiomisc](https://github.com/aiokitchen/aiomisc) 18.0.42 | `CircuitBreaker` never opens when calls fail slowly or come at most once per bucket | [aiomisc#261](https://github.com/aiokitchen/aiomisc/issues/261) |
| [pyrate_limiter.hz](pyrate_limiter.hz) | [PyrateLimiter](https://github.com/vutran1710/PyrateLimiter) 4.5.1 | `try_acquire_async` holds its lock while it sleeps, so `blocking=False` calls and other keys wait | [PyrateLimiter#339](https://github.com/vutran1710/PyrateLimiter/issues/339) |
