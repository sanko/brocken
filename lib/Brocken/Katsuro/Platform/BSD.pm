use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::BSD : isa(Brocken::Katsuro::Platform) {
    method is_bsd() {1}
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::BSD - Generic BSD Platform Abstraction

=head1 DESCRIPTION

Base class for BSD-derived platforms. Provides a common C<is_bsd()> method shared by FreeBSD, OpenBSD, NetBSD,
MidnightBSD, and DragonFly BSD.

=head1 METHODS

=head2 is_bsd

Returns true (1). Subclasses inherit this identity method.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
