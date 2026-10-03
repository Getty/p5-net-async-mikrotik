#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use_ok('Net::Async::MikroTik');

diag 'WWW::MikroTik '.WWW::MikroTik->VERSION.' from '.$INC{'WWW/MikroTik.pm'};

ok( WWW::MikroTik->can('build_request') && WWW::MikroTik->can('parse_response'),
  'WWW::MikroTik has the build_request/parse_response seam' );

done_testing;
