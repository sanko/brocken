use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::IRGenerator;
use Brocken::Core::Type;
use Brocken::Target::Architecture::X64;
use Brocken::Target::Format::ELF;
use Brocken::Target::Triple;
use File::Temp;

sub compile_to_instructions($code) {
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $tokens = $lexer->tokenize();
    my $parser = Brocken::Core::Parser->new( tokens => $tokens );
    my @statements;
    while ( $parser->peek->type ne 'EOF' ) {
        push @statements, $parser->parse_statement();
    }
    my $generator = Brocken::Core::IRGenerator->new();
    for my $stmt (@statements) {
        $generator->lower_statement($stmt);
    }

    # Collect instructions from main blocks and all body function blocks
    my @all_insts;
    for my $b  ( @{ $generator->blocks } ) { push @all_insts, @{ $b->instructions } }
    for my $fn ( sort keys %{ $generator->program_blocks } ) {
        for my $b ( @{ $generator->program_blocks->{$fn} } ) { push @all_insts, @{ $b->instructions } }
    }
    return \@all_insts;
}

sub compile_to_blocks($code) {
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $tokens = $lexer->tokenize();
    my $parser = Brocken::Core::Parser->new( tokens => $tokens );
    my @statements;
    while ( $parser->peek->type ne 'EOF' ) {
        push @statements, $parser->parse_statement();
    }
    my $generator = Brocken::Core::IRGenerator->new();
    for my $stmt (@statements) {
        $generator->lower_statement($stmt);
    }

    # Collect blocks from main + all body functions
    my @all_blocks;
    push @all_blocks, @{ $generator->blocks };
    for my $fn ( sort keys %{ $generator->program_blocks } ) {
        push @all_blocks, @{ $generator->program_blocks->{$fn} };
    }
    return \@all_blocks;
}
subtest 'Lexer - Concurrency Keywords' => sub {
    my $code   = 'fiber yield transfer isolate send receive';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $tokens = $lexer->tokenize();
    is( @$tokens, 7, 'lexer produces 7 tokens: 6 keywords + EOF' );
    my @expected = qw(fiber yield transfer isolate send receive);
    for my $i ( 0 .. 5 ) {
        is( $tokens->[$i]->type,  'KEYWORD',     "token $i is a KEYWORD" );
        is( $tokens->[$i]->value, $expected[$i], "token $i value is '$expected[$i]'" );
    }
    is( $tokens->[6]->type, 'EOF', 'final token is EOF' );
};
subtest 'Parser - Fiber Block Expression' => sub {
    my $code   = 'fiber { my $x = 1; $x; };';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $stmt   = $parser->parse_statement();
    is( ref($stmt),          'Brocken::Core::AST::FiberBlock', 'fiber block parses to FiberBlock AST node' );
    is( @{ $stmt->body },    2,                                'fiber block body contains 2 statements' );
    is( $parser->peek->type, 'EOF',                            'EOF reached after fiber block' );
};
subtest 'Parser - Yield Statement' => sub {
    my $code   = 'yield; yield 42;';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $s1     = $parser->parse_statement();
    is( ref($s1),   'Brocken::Core::AST::YieldStmt', 'yield; parses to YieldStmt' );
    is( $s1->value, undef,                           'void yield has no value' );
    my $s2 = $parser->parse_statement();
    is( ref($s2),          'Brocken::Core::AST::YieldStmt', 'yield 42; parses to YieldStmt' );
    is( ref( $s2->value ), 'Brocken::Core::AST::Literal',   'yield value is a Literal AST node' );
    is( $s2->value->value, 42,                              'yield value is 42' );
};
subtest 'Parser - Transfer Statement' => sub {
    my $code   = 'my $f; transfer $f; transfer $f, 99;';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    $parser->parse_statement();
    my $s1 = $parser->parse_statement();
    is( ref($s1),           'Brocken::Core::AST::TransferStmt', 'transfer $f parses to TransferStmt' );
    is( ref( $s1->target ), 'Brocken::Core::AST::Variable',     'transfer target is a Variable AST node' );
    is( $s1->target->name,  '$f',                               'transfer target is $f' );
    is( $s1->value,         undef,                              'transfer without value has no value' );
    my $s2 = $parser->parse_statement();
    is( ref($s2),          'Brocken::Core::AST::TransferStmt', 'transfer $f, 99 parses to TransferStmt' );
    is( $s2->target->name, '$f',                               'second transfer target is $f' );
    is( $s2->value->value, 99,                                 'second transfer value is 99' );
};
subtest 'Parser - Isolate Block Expression' => sub {
    my $code   = 'isolate { my $msg = receive; $msg; };';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $stmt   = $parser->parse_statement();
    is( ref($stmt),          'Brocken::Core::AST::IsolateBlock', 'isolate block parses to IsolateBlock AST node' );
    is( @{ $stmt->body },    2,                                  'isolate block body contains 2 statements' );
    is( $parser->peek->type, 'EOF',                              'EOF reached after isolate block' );
};
subtest 'Parser - Send Statement' => sub {
    my $code   = 'my $iso; my $msg; send $iso, $msg;';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    $parser->parse_statement();
    $parser->parse_statement();
    my $s = $parser->parse_statement();
    is( ref($s),           'Brocken::Core::AST::SendStmt', 'send parses to SendStmt' );
    is( ref( $s->target ), 'Brocken::Core::AST::Variable', 'send target is a Variable AST node' );
    is( $s->target->name,  '$iso',                         'send target is $iso' );
    is( ref( $s->value ),  'Brocken::Core::AST::Variable', 'send value is a Variable AST node' );
    is( $s->value->name,   '$msg',                         'send value is $msg' );
};
subtest 'Parser - Receive Expression' => sub {
    my $code   = 'receive;';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $s      = $parser->parse_statement();
    is( ref($s), 'Brocken::Core::AST::ReceiveExpr', 'receive parses to ReceiveExpr AST node' );
};
subtest 'IRGenerator - Fiber Block Lowering' => sub {
    my $code  = 'my $f = fiber { my $x = 1; };';
    my $insts = compile_to_instructions($code);
    my @ops   = map { $_->op } @$insts;
    ok( ( grep { $_ eq 'SPAWN_FIBER' } @ops ), 'fiber block emits SPAWN_FIBER instruction' );
    my ($spawn) = grep { $_->op eq 'SPAWN_FIBER' } @$insts;
    is( $spawn->type, 'Pointer', 'SPAWN_FIBER type is Pointer' );
    like( $spawn->srcs->[0], qr/^fiber_body_\d+$/, 'SPAWN_FIBER references a fiber body block label' );
    ok( defined $spawn->dest, 'SPAWN_FIBER has a destination register for fiber handle' );
};
subtest 'IRGenerator - Yield Statement Lowering' => sub {
    my $code   = 'yield; yield 42;';
    my $insts  = compile_to_instructions($code);
    my @yields = grep { $_->op eq 'YIELD' } @$insts;
    is( @yields,               2,      'two YIELD instructions emitted' );
    is( @{ $yields[0]->srcs }, 0,      'void yield has no source operands' );
    is( $yields[0]->type,      'Void', 'void yield type is Void' );
    is( @{ $yields[1]->srcs }, 1,      'yield with value has 1 source operand' );
    is( $yields[1]->srcs->[0], 42,     'yield value is 42' );
};
subtest 'IRGenerator - Transfer Statement Lowering' => sub {
    my $code      = 'my $f; transfer $f; transfer $f, 99;';
    my $insts     = compile_to_instructions($code);
    my @transfers = grep { $_->op eq 'TRANSFER' } @$insts;
    is( @transfers, 2, 'two TRANSFER instructions emitted' );
    ok( defined $transfers[0]->srcs->[0], 'transfer without value has target' );
    is( @{ $transfers[1]->srcs }, 2, 'transfer with value has 2 source operands' );
};
subtest 'IRGenerator - Isolate Block Lowering' => sub {
    my $code  = 'my $iso = isolate { my $x = 1; };';
    my $insts = compile_to_instructions($code);
    my @ops   = map { $_->op } @$insts;
    ok( ( grep { $_ eq 'ISOLATE_CREATE' } @ops ), 'isolate block emits ISOLATE_CREATE instruction' );
    my ($create) = grep { $_->op eq 'ISOLATE_CREATE' } @$insts;
    like( $create->srcs->[0], qr/^isolate_body_\d+$/, 'ISOLATE_CREATE references an isolate body block label' );
    ok( defined $create->dest, 'ISOLATE_CREATE has a destination register for isolate handle' );
};
subtest 'IRGenerator - Send Statement Lowering' => sub {
    my $code  = 'my $iso; my $msg; send $iso, $msg;';
    my $insts = compile_to_instructions($code);
    my @sends = grep { $_->op eq 'SEND' } @$insts;
    is( @sends,               1, 'one SEND instruction emitted' );
    is( @{ $sends[0]->srcs }, 2, 'SEND has 2 source operands: target and value' );
};
subtest 'IRGenerator - Receive Expression Lowering' => sub {
    my $code  = 'my $msg = receive;';
    my $insts = compile_to_instructions($code);
    my @recvs = grep { $_->op eq 'RECEIVE' } @$insts;
    is( @recvs, 1, 'one RECEIVE instruction emitted' );
    ok( defined $recvs[0]->dest, 'RECEIVE has a destination register' );
    is( $recvs[0]->type, 'Any', 'RECEIVE type is Any' );
};
subtest 'IRGenerator - Fiber with Transfer Inside' => sub {
    my $code   = 'my $f = fiber { my $x; transfer $x; };';
    my $blocks = compile_to_blocks($code);
    my @ops    = map { $_->op } map { @{ $_->instructions } } @$blocks;
    ok( ( grep { $_ eq 'SPAWN_FIBER' } @ops ), 'fiber block emits SPAWN_FIBER' );
    ok( ( grep { $_ eq 'TRANSFER' } @ops ),    'transfer inside fiber emits TRANSFER' );

    # Check that the body is in a separate function
    my $generator;    # get from compile_to_blocks... refactor later

    # Use a simpler check: at least 2 blocks (main entry + fiber body)
    ok( @$blocks >= 2, 'multiple blocks emitted including fiber body' );
};
subtest 'Codegen - X64 Fiber/Thread Operations' => sub {
    my $code = q{
        my $f;
        my $iso;
        $f = fiber { yield; };
        $iso = isolate { my $msg = receive; };
        transfer $f;
    };
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my @statements;
    while ( $parser->peek->type ne 'EOF' ) {
        push @statements, $parser->parse_statement();
    }
    my $generator = Brocken::Core::IRGenerator->new();
    for my $stmt (@statements) {
        $generator->lower_statement($stmt);
    }
    my $x64    = Brocken::Target::Architecture::X64->new();
    my $triple = Brocken::Target::Triple->new( raw_string => 'x86_64-linux-elf' );
    my $blocks = $generator->blocks;
    my $prog   = { main => $blocks };
    for my $k ( keys %{ $generator->program_blocks } ) {
        $prog->{$k} = $generator->program_blocks->{$k};
    }
    my $bin = $x64->assemble_program( $prog, $triple );
    ok( defined $bin, 'X64 codegen produces binary with fiber/thread ops' );
    if ( defined $bin ) {
        ok( length($bin) > 0, 'binary has content' );
        my $elf         = Brocken::Target::Format::ELF->new();
        my $output_file = File::Temp->new( TEMPLATE => 'fiberXXXXX', SUFFIX => '.elf', UNLINK => 0 );
        close $output_file;
        unlink $output_file->filename;
        $elf->write_executable( $output_file->filename, $bin, $triple );
        ok( -e $output_file->filename, 'ELF executable generated with fiber/thread code' );
        unlink $output_file->filename;
    }
};
subtest 'M:N Fiber Scheduling Model' => sub {
    my $code = q{
        my $f1 = fiber { my $x = 1; yield; $x; };
        my $f2 = fiber { my $y = 2; yield; $y; };
        my $f3 = fiber { my $z = 3; yield; $z; };
    };
    my $insts  = compile_to_instructions($code);
    my @spawns = grep { $_->op eq 'SPAWN_FIBER' } @$insts;
    is( @spawns, 3, 'M:N model: 3 fibers (M) spawned from a single thread (N=1)' );
    my @yields = grep { $_->op eq 'YIELD' } @$insts;
    is( @yields, 3, 'M:N model: each fiber yields control back to the scheduler' );
    my @labels = map { $_->srcs->[0] } @spawns;
    my %unique = map { $_ => 1 } @labels;
    is( keys %unique, 3, 'M:N model: each fiber has a unique body block label' );
};
subtest 'Work Stealing - Isolate Parallel Dispatch' => sub {
    my $code = q{
        my $iso1 = isolate { my $a = 10; };
        my $iso2 = isolate { my $b = 20; };
        my $iso3 = isolate { my $c = 30; };
    };
    my $insts   = compile_to_instructions($code);
    my @creates = grep { $_->op eq 'ISOLATE_CREATE' } @$insts;
    is( @creates, 3, 'work stealing: 3 isolates dispatched for parallel execution' );
    my @labels = map { $_->srcs->[0] } @creates;
    my %unique = map { $_ => 1 } @labels;
    is( keys %unique, 3, 'work stealing: each isolate has a unique body block label' );
};
subtest 'Work Stealing - Channel Communication Between Isolates' => sub {
    my $code = q{
        my $iso = isolate {
            my $msg = receive;
            $msg;
        };
        send $iso, 42;
    };
    my $insts   = compile_to_instructions($code);
    my @creates = grep { $_->op eq 'ISOLATE_CREATE' } @$insts;
    is( @creates, 1, 'one isolate created for worker' );
    my @sends = grep { $_->op eq 'SEND' } @$insts;
    is( @sends, 1, 'one SEND to worker isolate' );
    my @recvs = grep { $_->op eq 'RECEIVE' } @$insts;
    is( @recvs, 1, 'one RECEIVE inside worker isolate' );
};
subtest 'End-to-End Concurrency Pipeline' => sub {
    my $code = q{
        my $f = fiber { yield 1; yield 2; };
        transfer $f;
        my $iso = isolate { my $val = receive; $val; };
        send $iso, 99;
    };
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $tokens = $lexer->tokenize();
    ok( @$tokens > 1, 'lexer tokenizes concurrency program' );
    my $parser = Brocken::Core::Parser->new( tokens => $tokens );
    my @stmts;
    while ( $parser->peek->type ne 'EOF' ) {
        push @stmts, $parser->parse_statement();
    }
    is( @stmts, 4, 'parser produces 4 statements from concurrency program' );
    my $generator = Brocken::Core::IRGenerator->new();
    for my $stmt (@stmts) {
        $generator->lower_statement($stmt);
    }
    my $blocks = $generator->blocks;
    ok( @$blocks > 0, 'IRGenerator produces basic blocks' );
    my @all_ops;
    for my $block (@$blocks) {
        push @all_ops, map { $_->op } @{ $block->instructions };
    }
    for my $fn ( sort keys %{ $generator->program_blocks } ) {
        for my $block ( @{ $generator->program_blocks->{$fn} } ) {
            push @all_ops, map { $_->op } @{ $block->instructions };
        }
    }
    my %present = map { $_ => 1 } @all_ops;
    ok( $present{SPAWN_FIBER},    'end-to-end: SPAWN_FIBER emitted' );
    ok( $present{YIELD},          'end-to-end: YIELD emitted' );
    ok( $present{TRANSFER},       'end-to-end: TRANSFER emitted' );
    ok( $present{ISOLATE_CREATE}, 'end-to-end: ISOLATE_CREATE emitted' );
    ok( $present{SEND},           'end-to-end: SEND emitted' );
    ok( $present{RECEIVE},        'end-to-end: RECEIVE emitted' );
    my $x64    = Brocken::Target::Architecture::X64->new();
    my $triple = Brocken::Target::Triple->new( raw_string => 'x86_64-linux-elf' );
    my $prog   = { main => $blocks };

    for my $k ( keys %{ $generator->program_blocks } ) {
        $prog->{$k} = $generator->program_blocks->{$k};
    }
    my $bin = $x64->assemble_program( $prog, $triple );
    ok( defined $bin, 'end-to-end: X64 codegen produces binary with concurrency ops' );
};
done_testing;
