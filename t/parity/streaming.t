#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Nginx qw/:DEFAULT http_content/;
use IO::Socket::INET;
use Time::HiRes qw/time/;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

my $t = Test::Nginx->new()->has(qw/http proxy/);
my $plain = join '', map { sprintf "%08x stream %c\n", $_, $_ % 251 }
    (0 .. 4095);
$t->write_file('stream-body', $plain);
write_config($t, <<'EOF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    default_type text/plain;
    gzip off;
    zstd on;
    zstd_types *;
    zstd_http_version 1.0;
    zstd_proxied any;

    zstd_buffers 1 32;
    zstd_min_length 1m;
    zstd_max_length 1;
    server {
        listen 127.0.0.1:8080;
        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
        }
        location /postpone {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
            zstd_postpone 1m;
        }
        location /nobuffer {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
            zstd_no_buffer on;
        }
        location /tiny {
            proxy_pass http://127.0.0.1:8081;
            proxy_buffering off;
            zstd_buffers 1 1;
        }
    }
}
EOF
$t->run_daemon(\&origin, port(8081), $t->testdir());
$t->waitforsocket('127.0.0.1:' . port(8081));
$t->run();

for my $encoding (encodings()) {
    for my $location ('/', '/postpone', '/nobuffer', '/tiny') {
        my $key = $encoding . '_' . ($location =~ s/\///gr);
        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => port(8080),
            Proto => 'tcp', Timeout => 5) or die $!;
        $socket->autoflush(1);
        print $socket "GET $location?id=$key HTTP/1.1\r\nHost: localhost\r\n"
            . "Accept-Encoding: $encoding\r\nConnection: close\r\n\r\n";
        my $response = '';
        my $deadline = time() + 3;
        my $partial = '';
        while (time() < $deadline) {
            my $bits = '';
            vec($bits, fileno($socket), 1) = 1;
            next unless select($bits, undef, undef, 0.1);
            my $read = sysread($socket, my $buffer, 4096);
            last unless $read;
            $response .= $buffer;
            my (undef, $chunks) = split /\r\n\r\n/, $response, 2;
            next unless defined $chunks;
            $partial = '';
            while ($chunks =~ /\G([0-9a-f]+)\r\n/gci) {
                my $length = hex $1;
                last if length($chunks) - pos($chunks) < $length + 2;
                $partial .= substr($chunks, pos($chunks), $length);
                pos($chunks) += $length + 2;
            }
            # Wait briefly for the rest of the first flushed batch.
            last if length($partial) > 32;
        }
        ok(length($partial) > 0, "$encoding $location output before origin end");
        $t->write_file("release-$key", '1');
        $deadline = time() + 8;
        while (time() < $deadline) {
            my $bits = '';
            vec($bits, fileno($socket), 1) = 1;
            next unless select($bits, undef, undef, 0.1);
            my $read = sysread($socket, my $buffer, 8192);
            last unless $read;
            $response .= $buffer;
        }
        close $socket;
        check_response($t, $response, $encoding, $plain,
            "$encoding $location streamed round trip");
    }
}
# Close a client while its selected encoder is still active.
my ($abort_encoding) = encodings();
my $socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1',
    PeerPort => port(8080), Proto => 'tcp', Timeout => 5) or die $!;
print $socket "GET /?id=abort HTTP/1.1\r\nHost: localhost\r\n"
    . "Accept-Encoding: $abort_encoding\r\n\r\n";
sysread($socket, my $buffer, 512);
close $socket;
$t->write_file('release-abort', '1');
$t->write_file('release-after_abort', '1');
check_response($t, request('/?id=after_abort', $abort_encoding), $abort_encoding, $plain,
    'worker remains usable after client abort');

$t->stop();
unlike($t->read_file('error.log'), qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no streaming lifecycle errors');
undef $t;
done_testing();

sub origin {
    my ($port, $directory) = @_;
    exec 'python3', '-B', "$FindBin::Bin/lib/origin.py", $port, $directory;
    die "origin exec: $!";
}
