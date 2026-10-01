use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::Wasm : isa(Brocken::Katsuro::Platform) {
    method is_wasm()    {1}
    method is_posix()   { ( $self->os // '' ) =~ /wasi/i || ( $self->env // '' ) =~ /wasi/i }
    method bin_ext()    {'.wasm'}
    method lib_ext()    {'.wasm'}
    method format()     {'wasm'}
    method lib_prefix() {''}
}
1;
