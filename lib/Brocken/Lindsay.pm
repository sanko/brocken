package Brocken::Lindsay v0.0.1 {
    use v5.42;
    use feature qw[class];
    no warnings qw[experimental::class];
    use Brocken::Lindsay::IR;
    use Brocken::Lindsay::IR::Builder;
};

=encoding utf-8

=head1 NAME

Brocken::Lindsay - High-Level Intermediate Representation Module

=head1 DESCRIPTION

Lindsay is the front-end / middle-end of the Brocken compiler. It defines the high-level IR types and the builder API
used to construct IR programs. This package acts as a loader, importing the core IR classes (Brocken::Lindsay::IR) and
the builder (Brocken::Lindsay::IR::Builder).

=head2 Architecture

The Lindsay IR is an SSA-style representation inspired by LLVM IR, featuring:

=over 4

=item * B<Types>: Integer (i1/i8/i16/i32/i64/i128), Float (f32/f64), Pointer, Void, and Dynamic

=item * B<Values>: Instructions, Constants, and Basic Blocks forming a control-flow graph

=item * B<Instructions>: Arithmetic, memory (load/store/alloca), control flow (br/ret/call), and runtime operations (box/unbox/incref/decref)

=item * B<Builder>: A convenience API for constructing IR incrementally

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
