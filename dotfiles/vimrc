set background=dark
set nocompatible        " use vim extensions
" Bells
set visualbell t_vb=    " turn off error beep/flash
set novisualbell        " turn off visual bell
" Editing info
set number              "[same as nu] show line numbers
set ruler               "[same as ru] show cursor position
set showmode            "[same as smd] show when in insert mode
" Search
set hlsearch            " highlight searches
"set incsearch           " do incremental searching
" Auxilary files
set nobackup            " do not keep a backup file (ending in ~)
set noswapfile          " do not write a swap file
" Smart editing
set showmatch           "[same as sm] highlight matching (), {}, etc.
"set nowrap              " do not wrap lines
" Tabs and Indenting
set autoindent          "[same as ai] always set autoindenting on
set shiftwidth=4        "[same as sw] number of spaces to (auto)indent
set tabstop=4           "[same as ts] number of spaces per tab
set expandtab           "[same as et] use spaces instead of a tab
set softtabstop=4       "[same as sts] number of spaces to use instead of a tab
set smarttab            "[same as sta] <BS> deletes shiftwidth spaces from the start of a line
" Syntax highlighting
syntax enable
autocmd FileType make setlocal noexpandtab
set tags=./tags,tags;$HOME
set ignorecase
set smartcase
set listchars=eol:$,tab:>-,trail:~,extends:>,precedes:<
noremap <F5> :set list!<CR>

noremap <F6> :set number!<CR>
noremap <F7> :set paste!<CR>
nnoremap <Leader>s :%s/\<<C-r><C-w>\>/

set spelllang=en
set spellfile=$HOME/.vim/spell/en.utf-8.add
noremap <F8> :set spell!<CR>

autocmd FileType gitcommit setlocal spell

autocmd BufRead *.rs :setlocal tags=./rusty-tags.vi;/

" Highlight trailing spaces
" http://vim.wikia.com/wiki/Highlight_unwanted_spaces
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/
autocmd BufWinEnter * match ExtraWhitespace /\s\+$/
autocmd InsertEnter * match ExtraWhitespace /\s\+\%#\@<!$/
autocmd InsertLeave * match ExtraWhitespace /\s\+$/
autocmd BufWinLeave * call clearmatches()

"autocmd BufRead,BufNewFile /home/pdietl/git/starlab/lure/build/v4.19.56-1/* setlocal ts=8 sw=8 st=8 noexpandtab
"let g:load_doxygen_syntax=1

if has("autocmd")
  au BufReadPost * if line("'\"") > 0 && line("'\"") <= line("$")
    \| exe "normal! g'\"" | endif
endif
