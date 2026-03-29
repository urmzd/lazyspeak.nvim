if exists('g:loaded_lazyspeak')
  finish
endif
let g:loaded_lazyspeak = 1

command! LazySpeakStart lua require('lazyspeak').start()
command! LazySpeakStop lua require('lazyspeak').stop()
command! LazySpeakStatus lua vim.notify('[lazyspeak] ' .. require('lazyspeak').status())
command! LazySpeakUndo lua if require('lazyspeak')._core then require('lazyspeak')._core:handle_transcript('undo', 0) end
command! LazySpeakSnapshots lua vim.notify(vim.inspect(require('lazyspeak')._core and require('lazyspeak')._core.snapshots:list() or {}))
command! LazySpeakInstall lua require('lazyspeak.install').run()
