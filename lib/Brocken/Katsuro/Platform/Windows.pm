use v5.42;
use feature qw[class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::Windows : isa(Brocken::Katsuro::Platform) {
    method is_windows() {1}
    method is_posix()   {0}
    method bin_ext()    {'.exe'}
    method lib_ext()    {'.dll'}
    method format()     {'pe'}
    method lib_prefix() {''}

    method static_lib_ext() {
        return '.a' if $self->env eq 'gnu';
        return '.lib';
    }

    method shared_lib_name( $name, $version = undef ) {
        return $name . $self->lib_ext if !defined $version;
        return $name . '-' . $version . $self->lib_ext;
    }
}
1;
