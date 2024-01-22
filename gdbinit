python
import os
HOME = os.path.expanduser('~')
gdb.execute(f'add-auto-load-safe-path {HOME}')
gdb.set_parameter('history filename', f'{HOME}/.gdb_history')
end

set history save on
set history size unlimited
set print pretty on
set mem inaccessible-by-default off
