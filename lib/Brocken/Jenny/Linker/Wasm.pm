use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Jenny::Linker::Wasm v0.0.1 : isa(Brocken::Jenny::Linker) {
    use Fcntl qw[O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR];
    use Brocken::Katsuro::Platform;
    use Brocken::ICB ();

    # The address the bump allocator starts handing out from. 1024 rather
    # than 0, because 0 doubles as the out-of-memory answer: `bump_alloc`
    # returns it on exhaustion and `check_alloc` traps on it, so a heap that
    # began at 0 could never tell "the first block" from "no block".
    field $heap_base : param = 1024;

    # The heap the entry preamble tells the runtime it owns. A native link
    # backs that with an mmap that grows on demand, but a Wasm module declares
    # its memory once, in the initial memory section, and the allocator happily
    # hands out addresses across the whole heap it was promised. Reserving a
    # single page while promising 1MB meant the arena bookkeeping ran off the
    # end of linear memory: one boxed variable fit in what was actually there,
    # and a second trapped on an address past the memory.
    field $heap_size : param = Brocken::ICB::HEAP_SIZE;

    # The Wasm frame region sits above the arena rather than inside it. The
    # runtime's Immix arena runs from `heap_base + 144` for `heap_size` bytes,
    # and the Wasm lowering keeps its per-call frame bump in the space that
    # follows. Reserving it here means an allocation cannot walk into a live
    # frame; the lowering seeds `%heap_ptr` at exactly `heap_base + 144 +
    # heap_size`.
    use constant FRAME_RESERVE => 0x10000;

    # Four things have to fit: the base itself, the 144-byte ICB of runtime state
    # written there (cursor, limit, cap, free-list head, and the counters that
    # sit beside them), the whole arena, and the frame reserve above it. The
    # fixed single page this used to emit covered the default base of 1024 by
    # coincidence; a base above 64KB would have put the runtime state itself out
    # of bounds, and the frames had nowhere reserved for them at all.
    method _initial_pages () {
        my $pages = int( ( $heap_base + 144 + $heap_size + FRAME_RESERVE + 65535 ) / 65536 );
        return $pages < 1 ? 1 : $pages;
    }

    # Shared by both emission paths below, so the page count cannot drift
    # between them: the runtime reads this section to decide how much heap it
    # has, and the two paths used to build their own.
    method _memory_section () {
        my $content = pack( 'C', 1 ) . pack( 'C', 0 ) . $self->_uleb( $self->_initial_pages );
        return pack( 'C', 5 ) . $self->_uleb( length $content ) . $content;
    }

    # Global Section (ID 6): one mutable i64, the linear-memory frame bump
    # pointer. It has to be a global rather than a local because a Wasm local
    # belongs to one function. The bump pointer is shared by every function --
    # the caller carves its frame, then the callee carries on from where the
    # caller left off -- so a per-function copy let a callee hand out the same
    # addresses its caller was still using, and the caller's saved parameter
    # slots were overwritten mid-call. That is what made a runtime helper that
    # called another runtime helper read a clobbered pointer and fault.
    #
    # The initialiser is a constant; the entry sets it from the real heap base
    # before the first allocation.
    method _global_section () {

        # valtype 0x7E = i64, mutability 0x01 = var, init expr = i64.const 0; end
        my $entry   = pack( 'C', 0x7E ) . pack( 'C', 0x01 ) . pack( 'C', 0x42 ) . $self->_sleb(0) . pack( 'C', 0x0B );
        my $content = $self->_uleb(1) . $entry;
        return pack( 'C', 6 ) . $self->_uleb( length $content ) . $content;
    }

    # A `_start` export, so `wasmtime run module.wasm` runs the module as a
    # WASI command instead of needing `--invoke _BROCKEN_ENTRY` and a heap base
    # on the command line. The native linkers each have such a stub; this one
    # did not.
    #
    # A WASI `_start` is `() -> ()`, so it cannot supply a heap base the way
    # `_BROCKEN_ENTRY` takes one as a parameter, and passes the link-time one
    # itself. The entry's return value is dropped: propagating it would mean
    # importing wasi_snapshot_preview1.proc_exit, and this module emits no
    # import section, which would also break every caller that instantiates it
    # directly. So a program returning 42 and one returning 1 both exit 0. The
    # `drop` is emitted only when the entry actually leaves a value behind,
    # since dropping from an empty stack is itself a validation error.
    #
    # The base is pushed in the entry's own parameter type, which is i64
    # because a Wasm pointer is 64 bits. `i32.const` would make the call a type
    # error. `i32.const`/`i64.const` take a *signed* LEB128, hence _sleb rather
    # than the _uleb used for indices and section sizes; for a base of 1024 the
    # two encodings happen to agree, which is how the unsigned form could pass.
    method _start_body( $entry_index, $entry = undef ) {
        my $body   = pack( 'C', 0x00 );                                            # no locals
        my $vt     = $entry ? $entry->{param_valtypes}[0] : undef;
        my $is_i64 = defined $vt && $vt == 0x7E;
        $body .= pack( 'C', $is_i64 ? 0x42 : 0x41 ) . $self->_sleb($heap_base);    # i64.const / i32.const
        $body .= pack( 'C', 0x10 ) . $self->_uleb($entry_index);                   # call <entry>
        my $rt      = $entry      ? $entry->{return_valtype}                                : undef;
        my $returns = defined $rt ? ( ref $rt eq 'ARRAY' ? scalar $rt->@* : $rt ne 'void' ) : 1;
        $body .= pack( 'C', 0x1A ) if $returns;                                    # drop
        $body .= pack( 'C', 0x0B );                                                # end
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

            # The WASI command stub, appended once the indices exist so it can
            # name the entry. It carries no fixups: its call target is already
            # known. Only the multi-function path has the metadata _start_body
            # needs, so the single-function path below does not get one.
            if ( defined( my $entry_index = $func_offsets{_BROCKEN_ENTRY} ) ) {
                push @func_data,
                    {
                    name           => '_start',
                    bytes          => $self->_start_body( $entry_index, $func_data[$entry_index] ),
                    fixups         => [],
                    return_valtype => 'void',
                    param_valtypes => [],
                    };
            }

            # Resolve cross-function call fixups. Each 5-byte placeholder is
            # replaced by a shorter LEB128, so rebuild each function in a single
            # ordered pass rather than splicing in place and invalidating the
            # offsets of the fixups that follow.
            for my $fd (@func_data) {
                my @fixups = sort { $a->{offset} <=> $b->{offset} } $fd->{fixups}->@*;
                next unless @fixups;
                my $bytes = $fd->{bytes};
                my $out   = '';
                my $pos   = 0;
                for my $fixup (@fixups) {
                    next unless $fixup->{type} eq 'call_idx';
                    my $target_idx = $func_offsets{ $fixup->{target} };
                    die "Wasm write_executable: undefined function '$fixup->{target}'" unless defined $target_idx;
                    my $at = $fixup->{offset};
                    die "Wasm write_executable: call fixup out of range in $fd->{name}" if $at < $pos || $at + 5 > length($bytes);
                    $out .= substr( $bytes, $pos, $at - $pos );
                    $out .= $self->_uleb($target_idx);
                    $pos = $at + 5;
                }
                $fd->{bytes} = $out . substr( $bytes, $pos );
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

            # Memory Section (ID 5)
            my $mem_sec = $self->_memory_section;

            # Global Section (ID 6)
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

        if ( ref $ret_valtype eq 'ARRAY' ) {
            $type_sec = pack( 'C', 0x60 ) . "\x00" . pack( 'C', scalar $ret_valtype->@* ) . pack( 'C*', $ret_valtype->@* );
        }
        elsif ( $ret_valtype eq 'void' ) {
            $type_sec = pack( 'C', 0x60 ) . "\x00\x00";
        }
        else {
            $type_sec = pack( 'C', 0x60 ) . "\x00\x01" . pack( 'C', $ret_valtype );
        }
        $type_sec = pack( 'C', 1 ) . $self->_uleb( length($type_sec) + 1 ) . $self->_uleb(1) . $type_sec;

        # Memory Section (ID 5)
        my $mem_sec = $self->_memory_section;

        # Global Section (ID 6)
        my $global_sec = $self->_global_section;

        # Function Section (ID 3)
        my $func_sec = $self->_uleb(1) . $self->_uleb($type_idx);
        $func_sec = pack( 'C', 3 ) . $self->_uleb( length($func_sec) ) . $func_sec;

        # Export Section (ID 7)
        my $export_sec = $self->_uleb(1) . $self->_uleb( length($name) ) . $name . pack( 'C', 0x00 ) . $self->_uleb($func_idx);
        $export_sec = pack( 'C', 7 ) . $self->_uleb( length($export_sec) ) . $export_sec;

        # Code Section (ID 10)
        my $code_item = $self->_uleb( length($locals) + length($body) ) . $locals . $body;
        my $code_sec  = $self->_uleb(1) . $code_item;
        $code_sec = pack( 'C', 10 ) . $self->_uleb( length($code_sec) ) . $code_sec;
        die 'Wasm code section too large' if length($code_sec) > 268435456;
        sysopen my $fh, $output_file, O_WRONLY | O_CREAT | O_TRUNC or die $!;
        binmode $fh;
        print $fh "\0asm\x01\x00\x00\x00";
        print $fh $type_sec, $func_sec, $mem_sec, $global_sec, $export_sec, $code_sec;
        close $fh;
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

    # Signed LEB128: the same 7-bit groups, but the last one carries the sign, so
    # a value whose top group has bit 0x40 set needs an extra group the unsigned
    # form would not spend. `i32.const`/`i64.const` take this encoding.
    method _sleb ($v) {
        my $out = '';
        while (1) {
            my $byte = $v & 0x7F;
            $v >>= 7;
            my $done = ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) );
            $byte |= 0x80 unless $done;
            $out .= pack( 'C', $byte );
            last if $done;
        }
        return $out;
    }
} 1;
