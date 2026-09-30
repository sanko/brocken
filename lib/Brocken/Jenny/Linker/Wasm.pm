use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken::Jenny::Linker::Wasm v0.0.1 : isa(Brocken::Jenny::Linker) {
    use Brocken::Katsuro::Platform;
    use Fcntl qw[O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR];

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

            # Memory Section (ID 5): 1 page (64KB)
            my $mem_content = pack( 'C', 1 ) . pack( 'C', 0 ) . $self->_uleb(1);
            my $mem_sec     = pack( 'C', 5 ) . $self->_uleb( length($mem_content) ) . $mem_content;

            # Function Section (ID 3) -- map each function to its type
            my $func_sec = '';
            for my $fd (@func_data) {
                my $params = join( ',', map { $_ // '0x7F' } $fd->{param_valtypes}->@* );
                my $ret    = ref $fd->{return_valtype} eq 'ARRAY' ? join( ',', @{ $fd->{return_valtype} } ) : $fd->{return_valtype};
                my $key    = "$params|$ret";
                $func_sec .= $self->_uleb( $type_map{$key} );
            }
            $func_sec = pack( 'C', 3 ) . $self->_uleb( length($func_sec) + 1 ) . $self->_uleb( scalar @func_data ) . $func_sec;

            # Global Section (ID 6): the heap base, as one mutable i32. It is
            # seeded at run time by the entry stub below rather than here,
            # because the heap base arrives as an argument to _BROCKEN_ENTRY.
            # The allocator's own cursor, limit and cap live in the first bytes
            # of the heap itself, so this global only has to carry the base.
            my $global_content = pack( 'C', 1 )            # 1 global
                . pack( 'C', 0x7F )                        # valtype i32
                . pack( 'C', 0x01 )                        # mutable
                . pack( 'C', 0x41 ) . pack( 'C', 0x00 )    # i32.const 0
                . pack( 'C', 0x0B );                       # end
            my $global_sec = pack( 'C', 6 ) . $self->_uleb( length($global_content) ) . $global_content;

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

        # Memory Section (ID 5): 1 page (64KB)
        my $mem_content = pack( 'C', 1 ) . pack( 'C', 0 ) . $self->_uleb(1);
        my $mem_sec     = pack( 'C', 5 ) . $self->_uleb( length($mem_content) ) . $mem_content;

        # Function Section (ID 3)
        my $func_sec = $self->_uleb(1) . $self->_uleb($type_idx);
        $func_sec = pack( 'C', 3 ) . $self->_uleb( length($func_sec) ) . $func_sec;

        # Global Section (ID 6): the heap base, as in the multi-function path
        # above. The section is always emitted so both paths produce the same
        # module shape.
        my $global_content = pack( 'C', 1 ) . pack( 'C', 0x7F ) . pack( 'C', 0x01 ) . pack( 'C', 0x41 ) . pack( 'C', 0x00 ) . pack( 'C', 0x0B );
        my $global_sec     = pack( 'C', 6 ) . $self->_uleb( length($global_content) ) . $global_content;

        # Publish the heap base, as in the multi-function path above.
        if ( $name eq '_BROCKEN_ENTRY' ) {
            $body = pack( 'C', 0x20 ) . pack( 'C', 0x00 ) . pack( 'C', 0x24 ) . pack( 'C', 0x00 ) . $body;
        }

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
};
#
1;
