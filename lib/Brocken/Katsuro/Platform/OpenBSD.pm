use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::OpenBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_openbsd() {1}
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::OpenBSD - OpenBSD Platform

=head1 DESCRIPTION

Concrete platform class for OpenBSD. Inherits from B<BSD>.

=head1 METHODS

=head2 is_openbsd

Returns true (1).

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
