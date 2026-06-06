use v5.38;
use feature 'class';
no warnings 'experimental::class';

# A standard Immix memory Line (typically 128 bytes)
class Brocken::Runtime::Memory::Line {
    field $size   : param  : reader = 128;
    field $status : writer : reader = 'FREE';    # 'FREE', 'ALLOCATED', 'MARKED'
}

# A standard Immix memory Block (typically 32KB)
class Brocken::Runtime::Memory::Block {
    field $id     : param : reader;
    field $size   : param : reader = 32768;      # 32KB Block Size
    field $lines  : reader;
    field $status : writer : reader = 'FREE';    # 'FREE', 'ACTIVE', 'FULL', 'RECYCLABLE'
    ADJUST {
        $lines = [];

        # Allocate exactly 256 lines (256 * 128 bytes = 32KB)
        for ( my $i = 0; $i < 256; $i++ ) {
            push @$lines, Brocken::Runtime::Memory::Line->new();
        }
    }

    # Searches for a contiguous block of free lines to fit an object allocation
    method find_free_lines ($required_count) {
        my $contiguous = 0;
        my $start_idx  = -1;
        for ( my $i = 0; $i < 256; $i++ ) {
            if ( $lines->[$i]->status eq 'FREE' ) {
                $start_idx = $i if $contiguous == 0;
                $contiguous++;
                return $start_idx if $contiguous == $required_count;
            }
            else {
                $contiguous = 0;
                $start_idx  = -1;
            }
        }
        return -1;    # Does not fit in this block
    }

    # Allocates a span of lines and returns their raw index
    method allocate_span ( $start_idx, $count ) {
        for ( my $i = $start_idx; $i < $start_idx + $count; $i++ ) {
            $lines->[$i]->set_status('ALLOCATED');
        }
        $status = 'ACTIVE';
        return $start_idx;
    }

    # Sweeps marked lines and reclaims dead lines
    method sweep() {
        my $free_lines = 0;
        for my $line (@$lines) {
            if ( $line->status eq 'MARKED' ) {
                $line->set_status('ALLOCATED');    # Retain object
            }
            elsif ( $line->status eq 'ALLOCATED' ) {
                $line->set_status('FREE');         # Reclaim line
                $free_lines++;
            }
            else {
                $free_lines++;
            }
        }

        # Update block status on sweep completion
        if ( $free_lines == 256 ) {
            $status = 'FREE';
        }
        elsif ( $free_lines > 0 ) {
            $status = 'RECYCLABLE';
        }
        else {
            $status = 'FULL';
        }
    }
}

# The Global Immix Allocator
class Brocken::Runtime::Memory::Allocator {
    field $blocks : reader;
    field $next_block_id = 0;
    ADJUST {
        $blocks = [];
        $self->request_new_block();
    }

    method request_new_block() {
        my $new_block = Brocken::Runtime::Memory::Block->new( id => $next_block_id++ );
        push @$blocks, $new_block;
        return $new_block;
    }

    # Allocates space on the managed heap for a typed object of a specific byte-size
    method allocate ($byte_size) {

        # Calculate how many 128-byte lines are required (rounding up)
        my $required_lines = ( $byte_size + 127 ) >> 7;

        # Iterate over active blocks to find a line fit
        for my $block (@$blocks) {
            next if $block->status eq 'FULL';
            my $start_idx = $block->find_free_lines($required_lines);
            if ( $start_idx >= 0 ) {
                my $line_idx = $block->allocate_span( $start_idx, $required_lines );
                return { block_id => $block->id, line_idx => $line_idx, address => ( $block->id * 32768 ) + ( $line_idx * 128 ), };
            }
        }

        # If no active block fits, request a new block and retry
        my $fresh_block = $self->request_new_block();
        my $start_idx   = $fresh_block->find_free_lines($required_lines);
        my $line_idx    = $fresh_block->allocate_span( $start_idx, $required_lines );
        return { block_id => $fresh_block->id, line_idx => $line_idx, address => ( $fresh_block->id * 32768 ) + ( $line_idx * 128 ), };
    }
}
#
1;
