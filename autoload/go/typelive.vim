" Support for live error checking and displaying.

""
" Enables Go auto type live support.
function! go#typelive#AutoTypeLiveEnable() abort
  if get(s:, 'auto_type_live', 0)
    return
  endif

  if !has('timers')
    call go#util#EchoError('GoTypeLive requires "timers". Update your ' .
        \ 'Vim/Neovim version.')
    return
  endif

  let s:auto_type_live = 1
  let s:buf_list = []
  call go#util#EchoProgress('auto type live_enabled')
  call s:TypesLive(-1)

  augroup vim-go_typelive
    autocmd!

    autocmd BufWinEnter,TextChanged,TextChangedI *.go
        \ call s:TypesLiveWithDelay(get(g:, 'go_updatetime', 800))

    autocmd BufDelete *.go
        \ call filter(s:buf_list, 'v:val != ' . expand('<abuf>'))

    autocmd CursorMoved *.go
        \ call s:TypesLiveMessageWithDelay(get(g:, 'go_updatetime', 800))
    autocmd InsertLeave,CursorHold *.go call s:TypesLiveMessageWithDelay(0)
  augroup end
endfunction

""
" Disables Go auto type live support.
function! go#typelive#AutoTypeLiveDisable() abort
  if !get(s:, 'auto_type_live', 0)
    return
  endif

  " Remove the auto commands we have defined.
  augroup vim-go_typelive
    autocmd!
  augroup end

  call go#util#EchoProgress('auto type live disabled')
  unlet s:auto_type_live

  " Clear highlights and remove variables from all affected the buffers. The
  " following commands perform a buffer switch that's why we need to call them
  " with a bang in case there are some unsaved changes in them. We also need to
  " restore the buffer and cursor to its original position.
  let l:cur = bufnr('%')
  let l:pos = getcurpos()
  for l:buf in s:buf_list
    if !bufexists(l:buf)
      continue
    endif

    execute l:buf . 'bufdo! execute s:ClearTypesLive() | unlet b:matched b:pos'
  endfor
  execute 'buffer! ' . l:cur
  call setpos('.', l:pos)

  unlet s:buf_list
endfunction

""
" Toggles Go auto type live support between enabled and disabled state.
function! go#typelive#ToggleAutoTypeLive() abort
  if get(s:, 'auto_type_live', 0)
    call go#typelive#AutoTypeLiveDisable()
    return
  end

  call go#typelive#AutoTypeLiveEnable()
endfunction

" Calls a message display function with a delay. It will be called immediately
" if {delay} is a non-positive Number. If this function is called while there is
" already another message pending to be displayed, the previous call will be
" cancelled.
function! s:TypesLiveMessageWithDelay(delay) abort
  if get(b:, 'timer_message', 0)
    call timer_stop(b:timer_message)
    unlet b:timer_message
  endif

  if a:delay > 0
    function! CallBack(timer) abort
      call s:TypesLiveMessage(a:timer)
      if exists('b:timer_message')
        unlet b:timer_message
      endif
    endfunction
    let b:timer_message = timer_start(a:delay, 'CallBack')
    return
  endif

  call s:TypesLiveMessage(-1)
endfunction

" Displays an error message for the current cursor line if any. If this function
" was called with a delay, {timer} will be a positive Number.
function! s:TypesLiveMessage(timer) abort
  " Don't run if this feature has been disabled.
  if !get(s:, 'auto_type_live', 0)
    return
  endif

  " Output message only when in normal mode and when there could be anything to
  " output.
  if mode() !=# 'n' || !exists('b:matched')
    return
  endif

  " Check if user has actually done any movement. This should prevent executing
  " this procedure when called several times at a time by different auto
  " commands.
  let l:pos = line('.')
  if l:pos == b:pos
    return
  endif
  let b:pos = l:pos

  for l:line in b:matched
    if l:line['lnum'] != l:pos
      continue
    endif

    for l:match in getmatches()
      if l:line['id'] != l:match['id']
        continue
      endif

      call go#util#EchoError('Error "' . l:line['text'] . '" on column ' .
          \ l:line['col'])
      break
    endfor
  endfor
endfunction

" Calls an error checking function with a delay. It will be called immediately
" if {delay} is a non-positive Number. If this function is called while there is
" already another pending error check to be performed, the previous call will be
" cancelled.
function! s:TypesLiveWithDelay(delay) abort
  if get(b:, 'timer', 0)
    call timer_stop(b:timer)
    unlet b:timer
  endif

  if a:delay > 0
    function! CallBack(timer) abort
      call s:TypesLive(a:timer)
      if exists('b:timer')
        unlet b:timer
      endif
    endfunction
    let b:timer = timer_start(a:delay, 'CallBack')
    return
  endif

  call s:TypesLive(-1)
endfunction

" Runs an error check on the content in the current buffer and adds an error
" highlight group to those lines containing them. If this function was called
" with a delay, {timer} will be a positive Number
function! s:TypesLive(timer) abort
  " Don't run if this feature has been disabled.
  if !get(s:, 'auto_type_live', 0)
    return
  endif

  " Create a local matched list if first time running this command.
  if !exists('b:matched')
    let b:matched = []
    call add(s:buf_list, bufnr('%'))
  endif

  " (Re)set cursor variable due to text change.
  let b:pos = -1

  " Run after calling gotype-live to reduce flicker.
  call s:ClearTypesLive()

  for l:error in s:GetTypesLive()
    " TODO: Match only up until the last NON-blank character.
    call add(b:matched, {
        \ 'id': matchadd('SpellBad', '\v%' . l:error['lnum'] . 'l\S.*'),
        \ 'lnum': l:error['lnum'],
        \ 'col': l:error['col'],
        \ 'text': l:error['text'],
        \ })
  endfor
endfunction

" Get any errors for the current buffer.
function! s:GetTypesLive() abort
  " TODO: Execute this asynchronously.
  let l:errors = []
  let l:filename = expand('%:p')
  let [l:out, l:err] = go#util#Exec(['gotype-live', '-a', '-e',
      \ '-lf=' . l:filename, expand('%:p:h')], getline(1, '$'))

  " In case of syntax error, tool returns exit status code of 2.
  if empty(l:out) || l:err != 2
    return l:errors
  endif

  for l:line in split(l:out, "\n")
    let l:tokens = matchlist(l:line, '\v^(.{-1,}):(\d+):(\d+): (.+)')
    if !empty(l:tokens) && l:tokens[1] ==# l:filename
      call add(l:errors, {
          \ 'lnum': str2nr(l:tokens[2]),
          \ 'col': str2nr(l:tokens[3]),
          \ 'text': l:tokens[4],
          \ })
    endif
  endfor

  return l:errors
endfunction

" Removes any highlight group set by this script.
function! s:ClearTypesLive() abort
  if !exists('b:matched') || empty(b:matched)
    return 0
  endif

  for l:line in b:matched
    call matchdelete(l:line['id'])
  endfor
  let b:matched = []

  return 1
endfunction

" vim: sw=2 ts=2 et
