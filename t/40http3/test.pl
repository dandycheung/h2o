use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use Getopt::Long;
use Net::EmptyPort qw(wait_port);
use File::Temp qw(tempdir);
use Test::More;
use t::Util;

my $io_uring_batch_size;

GetOptions(
    'batch-size=i' => \$io_uring_batch_size
) or exit(1);

my $tempdir = tempdir(CLEANUP => 1);

my $client_prog = bindir() . "/h2o-httpclient";
plan skip_all => "$client_prog not found"
    unless -e $client_prog;

plan skip_all => "io_uring is not available"
    if $io_uring_batch_size && !server_features()->{io_uring};

my $quic_port = empty_port({
    host  => "127.0.0.1",
    proto => "udp",
});

sub doit {
    my $num_threads = shift;
    my $conf = << "EOT";
listen:
  type: quic
  port: $quic_port
  ssl:
    key-file: examples/h2o/server.key
    certificate-file: examples/h2o/server.crt
num-threads: $num_threads
hosts:
  default:
    paths:
      /:
        file.dir: t/assets/doc_root
EOT
    if (server_features()->{mruby}) {
        $conf .= << 'EOT';
      /echo:
        mruby.handler: |
          Proc.new do |env|
            [200, {}, [env["rack.input"].read]]
          end
EOT
    }
    if ($io_uring_batch_size) {
        $conf .= << "EOT";
file.io_uring: ON
io_uring-batch-size: $io_uring_batch_size
EOT
    } else {
        $conf .= << "EOT";
file.io_uring: OFF
EOT
    }
    my $guard = spawn_h2o($conf);
    wait_port({port => $quic_port, proto => 'udp'});
    for (1..100) {
        subtest "hello world" => sub {
            my $resp = `$client_prog -3 100 https://127.0.0.1:$quic_port 2>&1`;
            like $resp, qr{^HTTP/.*\n\nhello\n$}s;
        };
        subtest "large file" => sub {
            my $resp = `$client_prog -3 100 https://127.0.0.1:$quic_port/halfdome.jpg 2> $tempdir/log`;
            is $?, 0;
            diag do {
                open my $fh, "-|", "share/h2o/annotate-backtrace-symbols < $tempdir/log"
                    or die "failed to open $tempdir/log through annotated-backtrace-symbols:$?";
                local $/;
                <$fh>;
            } if $? != 0;
            is length($resp), (stat "t/assets/doc_root/halfdome.jpg")[7];
            is md5_hex($resp), md5_file("t/assets/doc_root/halfdome.jpg");
        };
        subtest "more than stream-concurrency" => sub {
            my $resp = `$client_prog -3 100 -t 1000 https://127.0.0.1:$quic_port 2> /dev/null`;
            is $resp, "hello\n" x 1000;
        };
        subtest "post" => sub {
            plan skip_all => 'mruby support is off'
                unless server_features()->{mruby};
            foreach my $cl (1, 100, 10000, 1000000) {
                my $resp = `$client_prog -3 100 -b $cl -c 100000 https://127.0.0.1:$quic_port/echo 2> /dev/null`;
                is length($resp), $cl;
                ok +($resp =~ /^a+$/s); # don't use of `like` to avoid excess amount of log lines on mismatch
            }
        };
    }
};

subtest "single-thread" => sub {
    doit(1);
};

subtest "multi-thread" => sub {
    doit(16);
};

subtest "slow-echo-chunked" => sub {
    plan skip_all => 'mruby support is off'
        unless server_features()->{mruby};

    my $guard = spawn_h2o(<< "EOT");
listen:
  type: quic
  port: $quic_port
  ssl:
    key-file: examples/h2o/server.key
    certificate-file: examples/h2o/server.crt
hosts:
  default:
    paths:
      /echo:
        mruby.handler: |
          Proc.new do |env|
            [200, {}, env["rack.input"]]
          end
EOT

    wait_port({port => $quic_port, proto => 'udp'});

    my $resp = `$client_prog -3 100 -t 5 -d 1000 -b 10 -c 2 -i 1000 https://127.0.0.1:$quic_port/echo 2> /dev/null`;
    is length($resp), 50;
    is $resp, 'a' x 50;
};

subtest "body-then-close" => sub {
    my $upstream = spawn_server(
        argv => [
            qw(plackup -s Starlet --max-workers 10 --access-log /dev/null --listen), "$tempdir/upstream.sock",
            ASSETS_DIR . "/upstream.psgi",
        ],
        is_ready => sub { !! -e "$tempdir/upstream.sock" },
    );
    my $server = spawn_h2o(<< "EOT");
http3-idle-timeout: 5
listen:
  type: quic
  port: $quic_port
  ssl:
    key-file: examples/h2o/server.key
    certificate-file: examples/h2o/server.crt
hosts:
  default:
    paths:
      /:
        proxy.reverse.url: http://[unix:$tempdir/upstream.sock]/
EOT
    my $fetch = sub {
        my $qp = shift;
        open my $fh, "-|", "$client_prog -3 100 https://127.0.0.1:$quic_port/suspend-body$qp 2>&1"
            or die "failed to spawn $client_prog:$!";
        local $/;
        join "", <$fh>;
    };
    like $fetch->(""), qr{^HTTP/3 200\n.*\n\nx$}s;
    like $fetch->("?delay-fin"), qr{^HTTP/3 200\n.*\n\nx$}s;
};

subtest "large-headers" => sub {
    my $server = spawn_h2o(<< "EOT");
listen:
  type: quic
  port: $quic_port
  ssl:
    key-file: examples/h2o/server.key
    certificate-file: examples/h2o/server.crt
hosts:
  default:
    paths:
      /:
        file.dir: t/assets/doc_root
EOT

    my $fetch = sub {
        my ($query, $opts) = @_;
        open my $fh, "-|", "$client_prog -3 100 $opts https://127.0.0.1:$quic_port/$query 2>&1"
            or die "failed to spawn $client_prog:$!";
        local $/;
        join "", <$fh>;
    };

    like $fetch->("", ""), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "no headers";

    # When generating headers, 'X' is used, as it is 8 bits in cleartext and also in static huffman.
    # TODO: can we check that the error is stream-level?
    subtest "single header" => sub {
        plan skip_all => "linux cannot handle args longer than 128KB"
            if $^O eq 'linux';
        like $fetch->("", "-H a:" . "X" x 409600), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly below limit";
        unlike $fetch->("", "-H a:" . "X" x 512000), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly above limit";
    };
    subtest "some large headers" => sub {
        like $fetch->("", join " ", map { "-H a:" . "X" x 65536 } (0..5)), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly below limit";
        unlike $fetch->("", join " ", map { "-H a:" . "X" x 65536 } (0..7)), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly above limit";
    };
    subtest "many headers" => sub {
        like $fetch->("", join " ", map { "-H a:" . "X" x 4096 } (0..90)), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly below limit";
        unlike $fetch->("", join " ", map { "-H a:" . "X" x 4096 } (0..110)), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly above limit";
    };
    subtest "URI" => sub {
        like $fetch->("?q=" . "X" x 120000, ""), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly below limit";
        subtest "above linux limit" => sub {
            plan skip_all => "linux cannot handle args longer than 128KB"
                if $^O eq 'linux';
            like $fetch->("?q=" . "X" x 409600, ""), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly below limit";
            unlike $fetch->("?q=" . "X" x 512000, ""), qr{^HTTP/3 200\n.*\n\nhello\n$}s, "slightly below limit";
        };
    };
};

done_testing;
