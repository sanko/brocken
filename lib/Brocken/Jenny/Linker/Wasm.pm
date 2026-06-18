use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker::Wasm : isa(Brocken::Jenny::Linker) {

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
                for my $fixup ( $fd->{fixups}->@* ) {
                    next unless $fixup->{type} eq 'call_idx';
                    my $target_idx = $func_offsets{ $fixup->{target} };
                    die "Wasm write_executable: undefined function '$fixup->{target}'" unless defined $target_idx;
                    my $leb = $self->_uleb($target_idx);
                    my $pos = $fixup->{offset};

                    # Replace the 5-byte placeholder with actual LEB128; string shrinks
                    substr( $fd->{bytes}, $pos, 5, $leb );
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
            open my $fh, '>:raw', $output_file or die $!;
            print $fh "\0asm\x01\x00\x00\x00";    # Magic + Version
            print $fh $type_sec, $func_sec, $mem_sec, $export_sec, $code_sec;
            close $fh;
            return;
        }

        # Single-function path (backward compat with hashref from emit_function)
        my $body        = $codegen_output->{body};
        my $locals      = $codegen_output->{locals};
        my $name        = 'main';
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

        # Export Section (ID 7)
        my $export_sec = $self->_uleb(1) . $self->_uleb( length($name) ) . $name . pack( 'C', 0x00 ) . $self->_uleb($func_idx);
        $export_sec = pack( 'C', 7 ) . $self->_uleb( length($export_sec) ) . $export_sec;

        # Code Section (ID 10)
        my $code_item = $self->_uleb( length($locals) + length($body) ) . $locals . $body;
        my $code_sec  = $self->_uleb(1) . $code_item;
        $code_sec = pack( 'C', 10 ) . $self->_uleb( length($code_sec) ) . $code_sec;
        open my $fh, '>:raw', $output_file or die $!;
        print $fh "\0asm\x01\x00\x00\x00";
        print $fh $type_sec, $func_sec, $mem_sec, $export_sec, $code_sec;
        close $fh;
    }

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
}
1;
