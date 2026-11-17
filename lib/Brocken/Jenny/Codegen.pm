use v5.42;

package Brocken::Jenny::Codegen v0.0.1 {

    #~ use Brocken::Jenny::Codegen::X86_64;
    #~ use Brocken::Jenny::Codegen::ARM64;
    #~ use Brocken::Jenny::Codegen::RISCV64;
    #~ use Brocken::Jenny::Codegen::Wasm;
    sub _collect_line_locs( $ir_fn, $blob ) {
        my $source_map = $blob->{source_map} // {};
        my $is_rt      = $ir_fn->name =~ /^Brocken::Runtime::/;
        my @locs;
        my $inst_idx = 0;
        my $last_key = '';
        for my $block ( $ir_fn->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                if ( $inst->line && defined $source_map->{$inst_idx} ) {
                    my $file = $is_rt ? '<runtime>' : ( $inst->file // '' );
                    my $off  = $source_map->{$inst_idx};
                    my $key  = "$off\0$file\0" . $inst->line . "\0" . ( $inst->col // 0 );
                    if ( $key ne $last_key ) {
                        push @locs, { offset => $off, file => $file, line => $inst->line, col => ( $inst->col // 0 ) };
                        $last_key = $key;
                    }
                }
                $inst_idx++;
            }
        }
        return \@locs;
    }
};
#
1;
