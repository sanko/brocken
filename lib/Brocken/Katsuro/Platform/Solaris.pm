use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::Solaris : isa(Brocken::Katsuro::Platform) {
    method is_solaris() {1}
    method format()     {'elf'}
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::Solaris - Solaris/Illumos Platform

=head1 DESCRIPTION

Concrete platform class for Solaris and illumos-derived systems. Uses ELF binary format.

=head1 METHODS

=head2 is_solaris

Returns true (1).

=head2 format

Returns 'elf'.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
