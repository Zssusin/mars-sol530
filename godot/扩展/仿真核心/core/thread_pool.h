// 小线程池：常驻工作线程 + 调用线程一起做 parallel_for。纯 C++17，不依赖 Godot（核心要能单测）。
// 用法：pool.parallel_for(n, [&](int64_t i) { … });  返回时 n 个任务都做完了。
// 线程数 ≤ 1 时在调用线程里串行做，结果与并行完全相同（调用方保证每个 i 只写自己的那份数据）。
// 同一时间只能有一个 parallel_for：另一个线程来调时，try_parallel_for 会在自己线程里串行做（不阻塞），parallel_for 会等。
#pragma once

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace marsim {

class ThreadPool {
public:
	// p_threads：总线程数（含调用线程）。0 = 自动：硬件线程数，最多 16。
	explicit ThreadPool(int p_threads = 0) { start(p_threads); }
	~ThreadPool() { stop(); }
	ThreadPool(const ThreadPool &) = delete;
	ThreadPool &operator=(const ThreadPool &) = delete;

	int threads() const { return int(workers_.size()) + 1; }

	void set_threads(int p_threads) {
		std::lock_guard<std::mutex> run(run_mutex_);
		stop();
		start(p_threads);
	}

	void parallel_for(int64_t p_n, const std::function<void(int64_t)> &p_fn) {
		std::lock_guard<std::mutex> run(run_mutex_);
		run_locked(p_n, p_fn);
	}

	// 线程池正被别人用时不等，直接在本线程串行做。
	void try_parallel_for(int64_t p_n, const std::function<void(int64_t)> &p_fn) {
		std::unique_lock<std::mutex> run(run_mutex_, std::try_to_lock);
		if (!run.owns_lock()) {
			for (int64_t i = 0; i < p_n; i++) {
				p_fn(i);
			}
			return;
		}
		run_locked(p_n, p_fn);
	}

private:
	std::vector<std::thread> workers_;
	std::mutex run_mutex_; // 一次只跑一个 parallel_for
	std::mutex m_;
	std::condition_variable cv_work_, cv_done_;
	const std::function<void(int64_t)> *fn_ = nullptr;
	int64_t n_ = 0;
	std::atomic<int64_t> next_{ 0 };
	uint64_t generation_ = 0;
	int busy_ = 0; // 正在做这一轮的工作线程数
	bool quit_ = false;

	void start(int p_threads) {
		int t = p_threads > 0 ? p_threads : int(std::thread::hardware_concurrency());
		t = std::clamp(t, 1, 16);
		quit_ = false;
		for (int i = 0; i < t - 1; i++) {
			workers_.emplace_back([this] { worker(); });
		}
	}

	void stop() {
		{
			std::lock_guard<std::mutex> lk(m_);
			quit_ = true;
		}
		cv_work_.notify_all();
		for (std::thread &w : workers_) {
			w.join();
		}
		workers_.clear();
	}

	void drain() {
		for (;;) {
			const int64_t i = next_.fetch_add(1, std::memory_order_relaxed);
			if (i >= n_) {
				return;
			}
			(*fn_)(i);
		}
	}

	void run_locked(int64_t p_n, const std::function<void(int64_t)> &p_fn) {
		if (p_n <= 0) {
			return;
		}
		if (workers_.empty() || p_n == 1) {
			for (int64_t i = 0; i < p_n; i++) {
				p_fn(i);
			}
			return;
		}
		{
			std::lock_guard<std::mutex> lk(m_);
			fn_ = &p_fn;
			n_ = p_n;
			next_.store(0, std::memory_order_relaxed);
			busy_ = int(workers_.size());
			generation_++;
		}
		cv_work_.notify_all();
		drain();
		std::unique_lock<std::mutex> lk(m_);
		cv_done_.wait(lk, [this] { return busy_ == 0; });
		fn_ = nullptr;
	}

	void worker() {
		uint64_t seen = 0;
		for (;;) {
			{
				std::unique_lock<std::mutex> lk(m_);
				cv_work_.wait(lk, [&] { return quit_ || generation_ != seen; });
				if (quit_) {
					return;
				}
				seen = generation_;
			}
			drain();
			{
				std::lock_guard<std::mutex> lk(m_);
				if (--busy_ == 0) {
					cv_done_.notify_one();
				}
			}
		}
	}
};

} // namespace marsim
