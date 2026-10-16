// >>> dotfiles-managed (browsers/zen/user.js) — install.sh copies this block into the active Zen profile.
// Memory / write-volume / cache limits from the workstation optimisation run. Applied on the next Zen start.
// Tab unloading before the system runs out of RAM (Zen's Linux default is false)
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("browser.low_commit_space_threshold_percent", 15);
// One shared content process per site group instead of four: fewer duplicated JS heaps
user_pref("dom.ipc.processCount.webIsolated", 1);
// Session store was rewritten every 15 s (most of Zen's disk writes); 60 s is plenty
user_pref("browser.sessionstore.interval", 60000);
// bfcache: keep at most 2 pages alive instead of 8 per tab
user_pref("browser.sessionhistory.max_total_viewers", 2);
// VA-API hardware video decode (radeonsi); verify in about:support -> Media
user_pref("media.hardware-video-decoding.force-enabled", true);
// Disk cache capped at 1 GiB (the value is in KiB)
user_pref("browser.cache.disk.smart_size.enabled", false);
user_pref("browser.cache.disk.capacity", 1048576);
// <<< dotfiles-managed
