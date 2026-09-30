use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken::Jenny::Linker::Wasm v0.0.1 : isa(Brocken::Jenny::Linker) {
    use Brocken::Katsuro::Platform;
    use Fcntl qw[O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR];

    # The address the bump allocator starts handing out from. 1024 rather
    # than 0, because 0 doubles as the out-of-memory answer: `bump_alloc`
    # returns it on exhaustion and `check_alloc` traps on it, so a heap that
    # began at 0 could never distinguish "the first block" from "no block".
    field $heap_base : param = 1024;

    # The runtime's heap header is 24 bytes (cursor, limit, cap) and lives at
    # the base, so the first page has to cover the base plus the header. The
    # old fixed single page happened to cover 1024, but a heap base above 64KB
    # would have put the header itself out of bounds.
    method _initial_pages () {
        my $needed = $heap_base + 24;
        my $pages  = int( ( $needed + 65535 ) / 65536 );
        return $pages < 1 ? 1 : $pages;
    }

    # Memory and global sections, shared by both emission paths below. The two
    # paths used to build their own, which is how the header offset drifted
    # between them and silently stopped array growth on one path only.
    method _memory_section () {
        my $mem_content = pack( 'C', 1 ) . pack( 'C', 0 ) . $self->_uleb( $self->_initial_pages );
        return pack( 'C', 5 ) . $self->_uleb( length $mem_content ) . $mem_content;
    }

    method _global_section () {
        my $global_content = pack( 'C', 1 )            # 1 global
            . pack( 'C', 0x7F )                        # valtype i32
            . pack( 'C', 0x01 )                        # mutable
            . pack( 'C', 0x41 ) . pack( 'C', 0x00 )    # i32.const 0
            . pack( 'C', 0x0B );                       # end
        return pack( 'C', 6 ) . $self->_uleb( length $global_content ) . $global_content;
    }

    # A `_start` export, so `wasmtime run module.wasm` works as a WASI
    # command rather than needing `--invoke _BROCKEN_ENTRY` and a heap base on
    # the command line.
    #
    # A WASI `_start` is `() -> ()`, so it cannot pass a heap base the way
    # `_BROCKEN_ENTRY` takes one as a parameter. It therefore supplies the
    # link-time base itself: `i32.const <base>; call <entry>; drop; end`. The
    # `drop` is what discards the entry's return value, since `_start` has no
    # way to report one -- WASI reads the exit status from `proc_exit`, which
    # this module does not import. That matches the native backends only in
    # that the value is discarded rather than propagated; see the note in
    # TODO.md on the missing `proc_exit` import.
    #
    # `i32.const` takes a *signed* LEB128, so the base is encoded with _sleb
    # rather than the _uleb used for indices and section sizes. For 1024 the
    # two agree, which is why the unsigned form would pass the tests.
    method _start_body($entry_index) {
        my $body = pack( 'C', 0x00 );                               # no locals
        $body .= pack( 'C', 0x41 ) . $self->_sleb($heap_base);      # i32.const <base>
        $body .= pack( 'C', 0x10 ) . $self->_uleb($entry_index);    # call <entry>
        $body .= pack( 'C', 0x1A );                                 # drop
        $body .= pack( 'C', 0x0B );                                 # end
        return $body;
    }

    method write_executable ( $output_file, $codegen_output, $platform ) {
        if ( ref $codegen_output eq 'ARRAY' ) {

            # Multi-function: array of {name, bytes, fixups, return_valtype}
            my @funcs = $codegen_output->@*;
            my %func_offsets;

            # Assign function indices and record type info
            my @func_data;
            for my $fd (@funcs) {
                $func_offsets{ $fd->{name} } = scalar(@func_data);
                push @func_data,
                    {
                    name           => $fd->{name},
                    bytes          => $fd->{bytes},
                    fixups         => $fd->{fixups}         // [],
                    return_valtype => $fd->{return_valtype} // 0x7F,
                    param_valtypes => $fd->{param_valtypes} // [],
                    };
            }

            # A `_start` export so the module runs as a WASI command. It joins
            # the same list as every other function, so it picks up a function
            # index, a type table entry, an export, and a code section slot
            # from the existing bookkeeping rather than each of those needing to
            # be taught about it separately.
            #
            # It is appended *after* the loop above, which means every real
            # function keeps the index it had, and the indices recorded in
            # $func_offsets stay valid.
            my $entry_index = $func_offsets{_BROCKEN_ENTRY};
            if ( defined $entry_index ) {
                push @func_data,
                    { name => '_start', bytes => $self->_start_body($entry_index), fixups => [], return_valtype => 'void', param_valtypes => [], };
            }

            # Resolve cross-function call fixups
            for my $fd (@func_data) {

                # A call placeholder is five bytes and the LEB128 that replaces
                # it is one or two, so every substitution shortens the buffer.
                # The encoder recorded its offsets against the untouched
                # function, so the fixups have to be applied in ascending offset
                # order while tracking how far the string has already shrunk.
                # Skipping that let the second call in a function overwrite the
                # wrong bytes and leave the placeholder's four continuation
                # bytes in front of the index, which the validator read as a
                # five-byte index of 0x30000000 and rejected as out of bounds.
                my $shift = 0;
                for my $fixup ( sort { $a->{offset} <=> $b->{offset} } $fd->{fixups}->@* ) {
                    next unless $fixup->{type} eq 'call_idx';
                    my $target_idx = $func_offsets{ $fixup->{target} };
                    die "Wasm write_executable: undefined function '$fixup->{target}'" unless defined $target_idx;
                    my $leb = $self->_uleb($target_idx);
                    my $pos = $fixup->{offset} - $shift;
                    substr( $fd->{bytes}, $pos, 5, $leb );
                    $shift += 5 - length($leb);
                }
            }

            # Build type types (deduplicate by param + return types)
            my %type_map;
            my @type_table;
            for my $fd (@func_data) {
                my $params = join( ',', map { $_ // '0x7F' } $fd->{param_valtypes}->@* );
                my $ret    = ref $fd->{return_valtype} eq 'ARRAY' ? join( ',', @{ $fd->{return_valtype} } ) : $fd->{return_valtype};
                my $key    = "$params|$ret";
                if ( !exists $type_map{$key} ) {
                    $type_map{$key} = scalar @type_table;
                    push @type_table, $fd;
                }
            }

            # WASM section IDs: 1=Type, 2=Import, 3=Function, 4=Table, 5=Memory, 6=Global, 7=Export, 8=Start, 9=Element, 10=Code, 11=Data
            # Value types: 0x7F=i32, 0x7E=i64, 0x7D=f32, 0x7C=f64
            # Functype opcode: 0x60
            # Type Section (ID 1)
            my $type_sec = '';
            for my $fd (@type_table) {
                my $params = '';
                for my $vt ( $fd->{param_valtypes}->@* ) {
                    $params .= pack( 'C', $vt // 0x7F );
                }
                my $rt = $fd->{return_valtype};
                if ( ref $rt eq 'ARRAY' ) {
                    $type_sec
                        .= pack( 'C', 0x60 ) .
                        $self->_uleb( scalar $fd->{param_valtypes}->@* ) .
                        $params .
                        pack( 'C',  scalar $rt->@* ) .
                        pack( 'C*', $rt->@* );
                }
                elsif ( $rt eq 'void' ) {
                    $type_sec .= pack( 'C', 0x60 ) . $self->_uleb( scalar $fd->{param_valtypes}->@* ) . $params . "\x00";
                }
                else {
                    $type_sec .= pack( 'C', 0x60 ) . $self->_uleb( scalar $fd->{param_valtypes}->@* ) . $params . "\x01" . pack( 'C', $rt );
                }
            }
            $type_sec = pack( 'C', 1 ) . $self->_uleb( length($type_sec) + 1 ) . $self->_uleb( scalar @type_table ) . $type_sec;

            # Memory Section (ID 5) and Global Section (ID 6) come from the
            # shared helpers, so the single-function path below cannot drift
            # from this one. They were duplicated until the heap header grew a
            # third word and one path's seed offset was left behind.
            my $mem_sec    = $self->_memory_section;
            my $global_sec = $self->_global_section;

            # Function Section (ID 3) -- map each function to its type
            my $func_sec = '';
            for my $fd (@func_data) {
                my $params = join( ',', map { $_ // '0x7F' } $fd->{param_valtypes}->@* );
                my $ret    = ref $fd->{return_valtype} eq 'ARRAY' ? join( ',', @{ $fd->{return_valtype} } ) : $fd->{return_valtype};
                my $key    = "$params|$ret";
                $func_sec .= $self->_uleb( $type_map{$key} );
            }
            $func_sec = pack( 'C', 3 ) . $self->_uleb( length($func_sec) + 1 ) . $self->_uleb( scalar @func_data ) . $func_sec;

            # Export Section (ID 7) -- export all named functions
            my $export_sec = '';
            for my $i ( 0 .. $#func_data ) {
                my $name = $func_data[$i]{name};
                $export_sec .= $self->_uleb( length($name) ) . $name . pack( 'C', 0x00 ) . $self->_uleb($i);
            }
            $export_sec = pack( 'C', 7 ) . $self->_uleb( length($export_sec) + 1 ) . $self->_uleb( scalar @func_data ) . $export_sec;

            # Publish the heap base to every frame. This has to run before any
            # body that allocates, so it goes in front of the entry function's
            # body -- and after the call fixups above, whose offsets are already
            # resolved against the un-prefixed bytes. _BROCKEN_ENTRY's first
            # parameter is %__heap_base, which is already the pointer to the
            # allocator header, so it is stored as-is. The header's +24 skip
            # that used to be here belongs to the cursor the runtime keeps, not
            # to the base passed to the allocator.
            for my $fd (@func_data) {
                next unless $fd->{name} eq '_BROCKEN_ENTRY';
                my $stub = pack( 'C', 0x20 ) . pack( 'C', 0x00 )    # local.get 0
                    . pack( 'C', 0x24 ) . pack( 'C', 0x00 );        # global.set 0
                my $at = $self->_locals_prefix_len( $fd->{bytes} );
                substr( $fd->{bytes}, $at, 0 ) = $stub;
                last;
            }

            # Code Section (ID 10)
            my $code_sec = '';
            for my $fd (@func_data) {
                $code_sec .= $self->_uleb( length( $fd->{bytes} ) ) . $fd->{bytes};
            }
            $code_sec = pack( 'C', 10 ) . $self->_uleb( length($code_sec) + 1 ) . $self->_uleb( scalar @func_data ) . $code_sec;
            die 'Wasm code section too large' if length($code_sec) > 268435456;
            sysopen my $fh, $output_file, O_WRONLY | O_CREAT | O_TRUNC or die $!;
            binmode $fh;

            # WASM magic number \0asm + version 1 (MVP)
            print $fh "\0asm\x01\x00\x00\x00";
            print $fh $type_sec, $func_sec, $mem_sec, $global_sec, $export_sec, $code_sec;
            close $fh;
            return;
        }

        # Single-function path (backward compat with hashref from emit_function)
        my $body        = $codegen_output->{body};
        my $locals      = $codegen_output->{locals};
        my $name        = $codegen_output->{name} // '_BROCKEN_ENTRY';
        my $type_idx    = 0;
        my $func_idx    = 0;
        my $ret_valtype = $codegen_output->{return_valtype} // 0x7F;
        my $type_sec;

        # A `_start` export alongside the single function, on the same terms as
        # the multi-function path: only for the real entry, and only reusing
        # type 0 when the function's own signature is already () -> ().
        # This path hardcodes a parameter count of zero in its type section
        # above, so the entry here never takes the heap-base argument the
        # multi-function one does.
        my $has_start       = $name eq '_BROCKEN_ENTRY';
        my $is_void_no_args = $has_start && !ref $ret_valtype && $ret_valtype eq 'void';
        my $start_type_idx  = $is_void_no_args ? 0 : 1;
        if ( ref $ret_valtype eq 'ARRAY' ) {
            $type_sec = pack( 'C', 0x60 ) . "\x00" . pack( 'C', scalar $ret_valtype->@* ) . pack( 'C*', $ret_valtype->@* );
        }
        elsif ( $ret_valtype eq 'void' ) {
            $type_sec = pack( 'C', 0x60 ) . "\x00\x00";
        }
        else {
            $type_sec = pack( 'C', 0x60 ) . "\x00\x01" . pack( 'C', $ret_valtype );
        }

        # The second type, () -> (), is only emitted when it is actually
        # referenced. `0x60 0x00 0x00` is a functype taking nothing and
        # returning nothing, which is the only signature WASI allows a
        # command's _start to have.
        my $type_count = 1;
        if ( $start_type_idx == 1 ) {
            $type_sec .= pack( 'C', 0x60 ) . "\x00\x00";
            $type_count = 2;
        }
        $type_sec = pack( 'C', 1 ) . $self->_uleb( length($type_sec) + 1 ) . $self->_uleb($type_count) . $type_sec;

        # Memory and global sections, from the shared helpers above.
        my $mem_sec    = $self->_memory_section;
        my $global_sec = $self->_global_section;

        # Function Section (ID 3). A section is id, size, then the vector: the
        # count is part of the counted payload, so the size has to cover the
        # count as well as the entries. Sizing the entries and then writing a
        # second count produces a module a validator reads as a corrupt export
        # table, so the count is built once here and measured with the rest.
        my $func_entries = $self->_uleb($type_idx);
        my $func_count   = 1;
        if ($has_start) {
            $func_entries .= $self->_uleb($start_type_idx);
            $func_count++;
        }
        my $func_sec = pack( 'C', 3 ) . $self->_uleb( length($func_entries) + 1 ) . $self->_uleb($func_count) . $func_entries;

        # Publish the heap base, as in the multi-function path above.
        if ( $name eq '_BROCKEN_ENTRY' ) {
            $body = pack( 'C', 0x20 ) . pack( 'C', 0x00 ) . pack( 'C', 0x24 ) . pack( 'C', 0x00 ) . $body;
        }

        # Export Section (ID 7), on the same count-then-size shape.
        my $export_entries = $self->_uleb( length($name) ) . $name . pack( 'C', 0x00 ) . $self->_uleb($func_idx);
        my $export_count   = 1;
        if ($has_start) {
            $export_entries .= $self->_uleb(6) . '_start' . pack( 'C', 0x00 ) . $self->_uleb(1);
            $export_count++;
        }
        my $export_sec = pack( 'C', 7 ) . $self->_uleb( length($export_entries) + 1 ) . $self->_uleb($export_count) . $export_entries;

        # Code Section (ID 10), same shape again.
        my $code_item    = $self->_uleb( length($locals) + length($body) ) . $locals . $body;
        my $code_entries = $code_item;
        my $code_count   = 1;
        if ($has_start) {

            # _start is a bare body with no locals of its own, so its code item
            # is the size followed by the body directly. The `drop` is only
            # correct when the entry left a value behind; a () -> () entry
            # leaves the stack empty and dropping from it is a validation
            # error, which is why the two cases share a type but not a body.
            my $start_body = $self->_start_body($func_idx);
            $start_body = pack( 'C', 0x41 ) . $self->_sleb($heap_base) . pack( 'C', 0x10 ) . $self->_uleb($func_idx) . pack( 'C', 0x0B )
                if $is_void_no_args;
            $code_entries .= $self->_uleb( length($start_body) ) . $start_body;
            $code_count++;
        }
        my $code_sec = pack( 'C', 10 ) . $self->_uleb( length($code_entries) + 1 ) . $self->_uleb($code_count) . $code_entries;
        die 'Wasm code section too large' if length($code_sec) > 268435456;
        sysopen my $fh, $output_file, O_WRONLY | O_CREAT | O_TRUNC or die $!;
        binmode $fh;
        print $fh "\0asm\x01\x00\x00\x00";
        print $fh $type_sec, $func_sec, $mem_sec, $global_sec, $export_sec, $code_sec;
        close $fh;
    }

    # A function body is the locals declaration followed by the expression, so
    # anything spliced into the front of the code has to go after the locals.
    # The declaration is a group count, then that many (count, valtype) pairs.
    method _locals_prefix_len($bytes) {
        my $pos          = 0;
        my $read_uleb_at = sub {
            my $b = ord substr( $bytes, $pos, 1 );
            $pos++;
            while ( $b & 0x80 ) { $b = ord substr( $bytes, $pos, 1 ); $pos++; }
            return $b;
        };
        my $groups = $read_uleb_at->();
        for ( 1 .. $groups ) {
            $read_uleb_at->();    # how many locals in this group
            $pos++;               # the group's single valtype byte
        }
        return $pos;
    }

    # Unsigned LEB128 encoding: emit 7-bit chunks with continuation bit 0x80,
    # MSB last. Used for WASM section sizes, function indices, and memory limits.
    method _uleb ($v) {
        my $out = '';
        do {
            my $byte = $v & 0x7F;
            $v >>= 7;
            $byte |= 0x80 if $v;
            $out .= pack( 'C', $byte );
        } while ($v);
        return $out;
    }

    # Signed LEB128, for i32.const. The arithmetic has to stay in integers for
    # the same reason it does in the codegen: `>>` on a negative value is an
    # unsigned shift, so a plain `$v >>= 7` would not round toward negative
    # infinity and the last group would be wrong.
    method _sleb ($v) {
        my $out = '';
        while (1) {
            my $byte = $v & 0x7F;
            $v = $v >= 0 ? $v >> 7 : -( ( -$v + 127 ) >> 7 );
            if ( ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) ) ) {
                $out .= pack( 'C', $byte );
                last;
            }
            $out .= pack( 'C', $byte | 0x80 );
        }
        return $out;
    }
};
#
1;
