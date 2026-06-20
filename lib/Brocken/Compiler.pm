use v5.42;
use feature qw[class];
no warnings qw[experimental::class];

class Brocken::Compiler { }

=encoding utf-8

=head1 NAME

Brocken::Compiler - Top-Level Compiler Frontend

=head1 DESCRIPTION

This class is the highest-level entry point for the Brocken compiler. It serves as the orchestration layer that
coordinates the three primary phases of compilation: parsing/IR generation (Lindsay), code generation (Jenny), and
platform abstraction (Katsuro).

Currently a stub class, it will eventually manage compiler state, configuration, and pass pipelines.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
