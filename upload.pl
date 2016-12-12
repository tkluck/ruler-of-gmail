#!/usr/bin/perl
use v5.14;
use warnings;
use version;
use Data::Dumper;
use Carp;
use XML::Output;

local $Data::Dumper::Terse=1;
local $Data::Dumper::Indent=1;
local $Data::Dumper::Sortkeys=1;
local $Data::Dumper::Deepcopy=1;

if (@ARGV != 2 || $ARGV[0] ne '-c') {
    die "Usage: $0 -c <config file>";
}
if (!-f $ARGV[1]) {
    die "Cannot find config file $ARGV[1]";
}

my %config;
PARSE_CONFIG: {
    open my $fh, '<', $ARGV[1];
    my $config_body= join '', <$fh>;
    close $fh;
    my $line= 1;

    my $config_error= sub { push @_, " at $ARGV[1] line $line\n"; goto &Carp::croak; };

    my $get_lexeme= sub {
        my $optional= shift;
        my $lexeme= '';
        my $in_quote;

        while ($config_body =~ s!
            \A
            (?:
                (?<ws>[ \t]+)
            |
                (?<nl>\n)
            |
                (?<comment>\#.*)
            |
                (?<standalone>[;\[\]\{\}])
            |
                (?<dq>"(?<inner>(?:[^\\"]++|(?:\\.)++)*+)")
            |
                (?<bare>[A-Za-z0-9_/.-]+)
            )
        !!x) {
            if ($+{nl})         { $line++; next }
            if ($+{ws})         { next; }
            if ($+{comment})    { next; }
            if ($+{standalone}) { return $+{standalone} }
            if ($+{dq})         { my $inner= $+{inner}; s/\\t/\t/g, s/\\n/\n/g, s/\\(.)/$1/g for $inner; return $inner }
            if ($+{bare})       { return $+{bare} };
        }
        if ($config_body) {
            $config_error->("Unexpected junk");
        } elsif (!$config_body and !$optional) {
            $config_error->("Unexpected EOF");
        }
    };

    my $get_string= $get_lexeme;

    my $get_object; $get_object= sub {
        my $lex= $get_lexeme->();
        if ($lex eq '[') {
            my @result = ('-or');
            while (my $obj= $get_object->()) {
                last if $obj eq ']';
                push @result, $obj;
            }
            return \@result;
        } else {
            return $lex;
        }
    };

    my $get_single_argument= sub {
        my $result= $get_object->();
        my $semicolon= $get_lexeme->();
        if ($semicolon ne ';') {
            $config_error->("Expected semicolon, found $semicolon");
        }
        return $result;
    };


    my %condmapsimple= (
        subject =>           "subject:",
        recipient =>         "to:",
        from =>              "from:",
        'subject-or-body' => "",
    );

    my $get_expression= sub {
        my $negate= 0;
        my $type= $get_object->();
        if ($type eq 'not') {
            $negate= 1;
            $type= $get_object->();
        }
        my $prefix= $condmapsimple{$type};
        if(!defined $prefix) {
            $config_error->("Unknown match type <$type>");
        }
        my $arg= $get_object->();
        my $result= $arg;
        $result= [$prefix => $result] if $prefix;
        $result= [-not => $result]     if $negate;
        return $result;
    };

    my %action_argc= (
        delete => 0,
        'apply-label' => 1,
        setread => 0,
    );
    my $get_action= sub {
        my $type= $get_lexeme->();
        if (!exists $action_argc{$type}) {
            $config_error->("Unknown action type: $type");
        }
        my %action= (type => $type);
        $action{$_}= $get_object->() for 0..($action_argc{$type}-1);
        return \%action;
    };

    my @exclusions_from_lastaction;

    sub AND {
        @_>1 ? [-and => @_] : @_;
    }
    sub OR {
        @_>1 ? [-or => @_] : @_;
    }

    my $get_rules; $get_rules= sub {
        my @parent_expressions= @_;
        my $expr= $get_expression->();
        my $bracket= $get_lexeme->(); $config_error->("Expected {") unless $bracket eq '{';

        my @merged_expr= (@parent_expressions, $expr);

        my @rules;
        while (1) {
            my $next= $get_lexeme->();
            if ($next eq '}') {
                last;
            } elsif ($next eq 'action' || $next eq 'last-action') {
                my $action= $get_action->();
                if(!@exclusions_from_lastaction) {
                    push @rules, Rule->new(AND(@merged_expr), $action, \%config);
                } else {
                    push @rules, Rule->new(
                        AND(@merged_expr, ['-not' => OR(@exclusions_from_lastaction)]),
                        $action, \%config);
                }
                if($next eq 'last-action') {
                    push @exclusions_from_lastaction, AND(@merged_expr);
                }
                $config_error->("Expected semicolon") unless $get_lexeme->() eq ';';
            } elsif ($next eq 'match') {
                my $subrules= $get_rules->(@merged_expr);
                push @rules, @$subrules;
            } else {
                $config_error->("Unexpected $next");
            }
        }
        return \@rules;
    };

    my $get_labels; $get_labels= sub {
        my @path= @_;

        my @new_labels;
        my $label_name= $get_string->();
        $config_error->("Expected { after label name") unless $get_lexeme->() eq '{';
        while (my $next= $get_lexeme->()) {
            if ($next eq '}') {
                last;
            } elsif ($next eq 'label') {
                push @new_labels, map "$label_name/$_", $get_labels->(@path, $label_name);
            } else {
                $config_error->("Unexpected $next in label block");
            }
        }
        push @new_labels, $label_name;
        return @new_labels;
    };

    my @all_rules;
    while (my $next= $get_lexeme->(1)) {
        if ($next eq 'name' || $next eq 'email') {
            if ($config{$next}) {
                $config_error->("Found multiple values for $next");
            }
            $config{$next}= $get_single_argument->();
        } elsif ($next eq 'match') {
            my $rules= $get_rules->();
            push @all_rules, @$rules;
        } elsif($next eq 'action') {
            my $action= $get_action->();
            push @all_rules, Rule->new([-not => OR(@exclusions_from_lastaction)], $action, \%config);
            $config_error->("Expected semicolon") unless $get_lexeme->() eq ';';
        } elsif($next eq 'last-action') {
            my $action= $get_action->();
            push @all_rules, Rule->new([-not => OR(@exclusions_from_lastaction)], $action, \%config);
            push @exclusions_from_lastaction, [-or => "dummy", "-dummy"];
            $config_error->("Expected semicolon") unless $get_lexeme->() eq ';';
        } elsif ($next eq 'label') {
            my @new_labels = $get_labels->();
            @{ $config{labels} }{@new_labels} = (1) x @new_labels;
       } else {
            $config_error->("Unexpected '$next'");
        }
    }

    $config{rules}= \@all_rules;
}

sub print_xml {
    my $xo= XML::Output->new({'fh' => *STDOUT});
    $xo->open('feed', {'xmlns' => 'http://www.w3.org/2005/Atom', 'xmlns:apps' => "http://schemas.google.com/apps/2006"});
    $xo->open('title'); $xo->pcdata("Mail Filters"); $xo->close();

    if($config{name} && $config{email}) {
        $xo->open('author');
        $xo->open('name'); $xo->pcdata($config{name}); $xo->close();
        $xo->open('email'); $xo->pcdata($config{email}); $xo->close();
        $xo->close();
    }

    for my $rule (@{ $config{rules} }) {
        $xo->open('entry');

        $xo->empty('category', {term => 'filter'});
        $xo->empty('apps:property', {
            name => 'hasTheWord',
            value => $rule->{criteria}{query},
        });
        my @actions = @{ $rule->{action} || [] };
        while(@actions) {
            my ($name, $value)= (shift @actions, shift @actions);
            $xo->empty('apps:property', {
                name => $name,
                value => $value,
            });
        }

        $xo->close();
    }
    $xo->close(); # feed
}

sub main {
    print STDERR Dumper(\%config);
    print_xml;
}

package Rule;
use v5.18;
use warnings;

sub name {
    my $self= shift;
    my $name= "";
    for my $prop (sort keys %$self) {
        next if $prop eq 'Name';
        $name .= " $prop";
        my $val= $self->{$prop};
        if (ref $val && ref $val eq 'ARRAY') {
            $name .= "=(@$val)" =~ s/[^a-zA-Z0-9().@\/\- ]+//rgs;
        } elsif (ref $val && ref $val eq 'HASH') {
            $name .= "=".($val->{DisplayName} // "(unknown)");
        } elsif (ref $val && $val->can('name')) {
            $name .= "=".$val->name;
        } else {
            $name .= "=$val";
        }
    }
    substr($name, 0, 1, '');
    return $name;
}

use constant {
    TRASH => "TRASH",
    INBOX => "INBOX",
    UNREAD => "UNREAD",
};

sub _to_gmail_query {
    my ($expression)= @_;

    return $expression unless ref $expression;

    my ($op, @args)= @$expression;
    if($op eq '-and') {
        return '('.join(" AND ", map _to_gmail_query($_), @args).')';
    } elsif($op eq '-or') {
        return '{'.join(" ", map _to_gmail_query($_), @args).'}';
    } elsif($op eq '-not') {
        die "invalid gmail query" unless @args == 1;
        return '-' . _to_gmail_query($args[0]);
    } elsif($op =~ /:$/) {
        die "invalid gmail query" unless @args == 1;
        return $op . _to_gmail_query($args[0]);
    } else {
        die "invalid gmail query, operator <$op> unknown";
    }
}

my %actions; BEGIN{ %actions= (
    delete  => [label            => TRASH],
    setread => [shouldMarkAsRead => 'true'],
); }

sub new {
    my ($class, $expression, $action, $config)= @_;

    my %properties;

    $properties{criteria}{query} =_to_gmail_query($expression);

    ACTION: {
        my $type= $action->{type};
        if ($type eq 'apply-label') {
            my $labelname= $action->{0};
            if(!defined $config->{labels}{$labelname}) {
                die "Undefined label: $labelname";
            }
            push @{ $properties{action} }, label => $labelname;
        } elsif(my $property= $actions{$type}) {
            push @{ $properties{action} }, @$property;
        } else {
            die "Unknown action type: $type";
        }
    }

    my $self= bless \%properties, $class;

    return $self;
}

main::main;
