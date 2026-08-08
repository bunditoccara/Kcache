#ifndef CIRCUIT_BREAKER_H_
#define CIRCUIT_BREAKER_H_

#include <chrono>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>

#include <spdlog/spdlog.h>

namespace kcache
{

    enum class CircuitState{
        Closed, // 正常，允许请求通过
        Open,   // 熔断，拒绝请求
        HalfOpen, // 半开，允许部分请求
    };

struct CircuitBreakerConfig {
    // 触发熔断的失败次数阈值（在滑动窗口内累计）
    int64_t failure_threshold = 5;
    // 熔断后多久进入 HalfOpen 状态（毫秒）
    int64_t recovery_timeout_ms = 5000;
    // HalfOpen 状态下允许通过的探测请求数
    int64_t half_open_max_calls = 2;
    // HalfOpen 状态下成功多少次后关闭熔断
    int64_t success_threshold = 2;
    // 失败计数器重置时间窗口（毫秒）：
    // - 在此窗口内发生的失败会被累积计数，一次成功不会清零
    // - 超过此窗口没有新失败后，下一次成功会重置计数器
    // - 解决 "失败-成功-失败-成功" 交替模式下熔断失效的问题
    int64_t failure_reset_timeout_ms = 10000;
};

// 熔断类
class CircuitBreaker {
public:
    using Permit = std::uint64_t;

    // 禁止隐式转换
    explicit CircuitBreaker(std::string name, CircuitBreakerConfig cfg = {})
        : name_(std::move(name)), cfg_(cfg) {}

    // 是否允许请求通过，处理三种状态流转
    std::optional<Permit> Allow() {
        std::lock_guard<std::mutex> lock(mutex_);
        // 未触发熔断
        if (state_ == CircuitState::Closed) {
            return generation_;
        }
        // 触发熔断
        if (state_ == CircuitState::Open) {
            // 检查是否到了恢复时间
            auto now = NowMs();
            // 检查是否超过恢复时间
            if (now - open_time_ms_ >= cfg_.recovery_timeout_ms) {
                state_ = CircuitState::HalfOpen;
                ++generation_;
                half_open_calls_ = 0;
                half_open_successes_ = 0;
                spdlog::warn("[CircuitBreaker:{}] -> HalfOpen", name_);
            } else {
                return std::nullopt;
            }
        }
        // HalfOpen：限制探测请求数
        if (state_ == CircuitState::HalfOpen) {
            if (half_open_calls_ >= cfg_.half_open_max_calls) {
                return std::nullopt;
            }
            ++half_open_calls_;
            return generation_;
        }
        return std::nullopt;
    }

    // 记录一次成功
    void RecordSuccess(Permit permit) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (permit != generation_) {
            return;
        }
        if (state_ == CircuitState::Closed) {
            // 不在 Closed 状态下简单清零 consecutive_failures_
            // 只有在距离最后一次失败超过 failure_reset_timeout_ms 后才清零
            // 防止 "失败-成功-失败-成功" 交替模式下的熔断失效：
            //   例如: F,F,F,F,S → 此前 consecutive_failures_=4，
            //   如果不重置，后续再失败就会累加到5触发熔断
            auto now = NowMs();
            auto last_fail = last_failure_time_ms_;
            if (last_fail == 0 || (now - last_fail) >= cfg_.failure_reset_timeout_ms) {
                consecutive_failures_ = 0;
            }
            return;
        }
        // 半开状态下请求成功
        if (state_ == CircuitState::HalfOpen) {
            auto succ = ++half_open_successes_;
            // 检查半开状态下请求成功次数是否抵达恢复阈值
            if (succ >= cfg_.success_threshold && succ == half_open_calls_) {
                state_ = CircuitState::Closed;
                ++generation_;
                // 失败计数清零
                consecutive_failures_ = 0;
                last_failure_time_ms_ = 0;
                open_time_ms_ = 0;
                half_open_calls_ = 0;
                half_open_successes_ = 0;
                spdlog::info("[CircuitBreaker:{}] -> Closed (recovered)", name_);
            }
        }
    }

    // 记录一次失败
    void RecordFailure(Permit permit) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (permit != generation_) {
            return;
        }
        if (state_ == CircuitState::HalfOpen) {
            // 探测失败，重新打开熔断
            open_time_ms_ = NowMs();
            half_open_calls_ = 0;
            half_open_successes_ = 0;
            state_ = CircuitState::Open;
            ++generation_;
            spdlog::warn("[CircuitBreaker:{}] HalfOpen probe failed -> Open", name_);
            return;
        }
        // 正常请求时失败
        if (state_ == CircuitState::Closed) {
            auto now = NowMs();
            auto last_fail = last_failure_time_ms_;
            // 如果距离上次失败超过重置窗口，说明之前的失败已经"过期"，先清零再计数
            if (last_fail > 0 && (now - last_fail) >= cfg_.failure_reset_timeout_ms) {
                consecutive_failures_ = 0;
            }
            last_failure_time_ms_ = now;
            auto failures = ++consecutive_failures_;
            if (failures >= cfg_.failure_threshold) {
                open_time_ms_ = now;
                half_open_calls_ = 0;
                half_open_successes_ = 0;
                state_ = CircuitState::Open; // 切换至熔断开状态
                ++generation_;
                spdlog::error("[CircuitBreaker:{}] -> Open (failures={})", name_, failures);
            }
        }
    }

    void Cancel(Permit permit) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (permit != generation_ || state_ != CircuitState::HalfOpen || half_open_calls_ == 0) {
            return;
        }

        --half_open_calls_;
        if (half_open_successes_ >= cfg_.success_threshold &&
            half_open_successes_ == half_open_calls_) {
            state_ = CircuitState::Closed;
            ++generation_;
            consecutive_failures_ = 0;
            last_failure_time_ms_ = 0;
            open_time_ms_ = 0;
            half_open_calls_ = 0;
            half_open_successes_ = 0;
            spdlog::info("[CircuitBreaker:{}] -> Closed (recovered)", name_);
        }
    }

    CircuitState State() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return state_;
    }

    std::string StateName() const {
        std::lock_guard<std::mutex> lock(mutex_);
        switch (state_) {
            case CircuitState::Closed:   return "Closed";
            case CircuitState::Open:     return "Open";
            case CircuitState::HalfOpen: return "HalfOpen";
        }
        return "Unknown";
    }

private:
    // 获取当前时间戳
    static int64_t NowMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now().time_since_epoch())
            .count();
    }

    std::string name_;
    CircuitBreakerConfig cfg_;

    mutable std::mutex mutex_;
    CircuitState state_{CircuitState::Closed};
    Permit generation_{0};
    int64_t consecutive_failures_{0};
    int64_t open_time_ms_{0};
    int64_t half_open_calls_{0};
    int64_t half_open_successes_{0};
    // 记录最近一次失败的时间戳，用于失败计数的时间窗口衰减
    int64_t last_failure_time_ms_{0};
};

} // namespace kcache
#endif
