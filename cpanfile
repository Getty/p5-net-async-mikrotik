requires 'Carp';
requires 'Future';
requires 'IO::Async';
requires 'Moo';
requires 'namespace::clean';
requires 'Net::Async::HTTP';
requires 'Scalar::Util';
requires 'WWW::MikroTik', '0.001';

# https:// (the default scheme) needs it; a plain-http lab router does not.
recommends 'IO::Async::SSL';

on test => sub {
  requires 'HTTP::Response';
  requires 'JSON::MaybeXS';
  requires 'Log::Any';
  requires 'Test::More';
};
