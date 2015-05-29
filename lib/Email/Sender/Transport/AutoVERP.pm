package Email::Sender::Transport::AutoVERP;
use Moo;
extends 'Email::Sender::Transport::Wrapper';

use Params::Util qw(_CODELIKE);
use Data::GUID qw(guid_string);

has batch_id_generator => (
  is  => 'ro',
  isa => sub { "batch_id_generator is not codelike" unless _CODELIKE($_[0]) },
  default => sub { sub { guid_string() } },
);

has delivery_id_generator => (
  is  => 'ro',
  isa => sub { "delivery_id_generator is not codelike" unless _CODELIKE($_[0]) },
  default => sub { sub { guid_string() } },
);

has env_from_generator => (
  is  => 'ro',
  isa => sub { "env_from_generator is not codelike" unless _CODELIKE($_[0]) },
  required => 1,
);

has result_logger => (
  is  => 'ro',
  isa => sub { "result_logger is not codelike" unless _CODELIKE($_[0]) },
  required => 1,
);

around send_email => sub {
  my ($orig, $self, $email, $env) = @_;

  my $batch_id_G    = $self->batch_id_generator;
  my $delivery_id_G = $self->delivery_id_generator;
  my $env_from_G    = $self->env_from_generator;

  my $batch_id = $self->$batch_id_G;

  # For some reason, I worry about whether I should bother uniq-ing the list of
  # to addresses.  I'm not going to sweat it for now. -- rjbs, 2015-05-29
  my @results;
  my @failures;

  for my $to (@{ $env->{to} }) {
    my $delivery_id = $self->$delivery_id_G({
      email    => $email,
      to       => $to,
      batch_id => $batch_id,
    });

    my $from = $self->$env_from_G({
      email       => $email,
      to          => $to,
      batch_id    => $batch_id,
      delivery_id => $delivery_id,
    });

    my $result = eval {
      $self->$orig($email, {
        %$env,
        from => $from,
        to   => [ $to ],
      });
    };

    unless ($result) {
      my $error  = $@;
      $result = eval { $error->isa('Email::Sender::Failure') } && $error;
      $result ||= Email::Sender::Failure->new({
        recipients => [ $to ],
        message    => "$error" || "unknown error during sending for $to",
      });

      push @failures, $result;
    }

    push @results, {
      to     => $to,
      from   => $from,
      result => $result,
      delivery_id => $delivery_id,
    };
  }

  if (@failures == @{ $env->{to} }) {
    Email::Sender::Failure::Multi->throw({ failures => @failures });
  }

  my $logged = eval {
    my $result_logger = $self->result_logger;
    $self->$result_logger($batch_id, \@results);
    1;
  };

  $self->handle_result_logging_failure($@, \@results) unless $logged;

  return Email::Sender::Success->new;
};

sub handle_result_logging_failure {
  my ($self, $error, $results) = @_;
  Carp::cluck("error logging results: $error");
}

1;
