package Text::Embed;

use strict;
use warnings;
use Carp;

our $VERSION  = '0.01';

my %modules   = ();
my %regexen   = ();
my %callbacks = ();
my %handles   = ();

my $rex_proc  = undef;
my $rex_parse = undef;

my $NL        = '(?:\r?\n)'; 

###########################################################################
# Default handlers for parsing
## 

my %def_parse  =
(
    ':underscore' => "$NL"."__([^_].*[^_])__$NL",
    ':define'     => "$NL#define[ \t]+(.+?)$NL",
    ':cdata'      => sub{$_ = shift or return; 
                       return($$_ =~ m#\s*?<!\[(.+?)\[(.*?)\]\]>\s*#sgo);
                     },
);

$def_parse{':default'} = $def_parse{':underscore'};
$rex_parse             = join('|', keys %def_parse);

###########################################################################
# Default handlers for processing
## 

my %def_proc  =
(
    ':raw'       => undef,
    ':trim'      => sub{ trim($_[1]);     },
    ':compress'  => sub{ compress($_[1]); },
    ':block'     => sub{ block($_[1]);    },

    ':strip-cpp' => sub{strip($_,'/\*','\*/'),strip($_, '//')foreach @_;},
    ':strip-c'   => sub{strip($_,'/\*','\*/')                foreach @_;},
    ':strip-xml' => sub{strip($_,'<!--','-->')               foreach @_;},
    ':strip-perl'=> sub{strip($_)                            foreach @_;},
);

$def_proc{':default'}  = $def_proc{':raw'};
$rex_proc              = join('|', keys %def_proc);

###########################################################################
# Import: 
# process arguments and tie caller's %DATA
##
sub import
{
    my $package = shift;
    my $regex   = shift;
    my $cback   = @_ ? [@_] : undef;
    my $caller  = caller;

    $regex = $def_parse{$regex}    if($regex && $regex =~ /^$rex_parse$/);
    $regex = $def_parse{':default'}unless $regex;

    if(!exists $modules{$caller})
    {
        no strict 'refs';
        # process all callbacks that are strings
        if($cback){
            foreach(@$cback){
                if(!ref $_){
                    if($_ =~ /^$rex_proc$/){
                        # predefined alias
                        $_ = $def_proc{$_};
                    }
                    else{
                        # stringy code ref - relative or absolute
                        $_ = ($_ =~ /\:\:/go) ? \&{$_} : 
                                                \&{$caller."\::".$_}; 
                    }
                }
            }
        }

        *{"$caller\::DATA"} = {};
        tie %{"$caller\::DATA"}, $package, $caller;

        $handles{$caller}   = \*{$caller."::DATA"};
        $modules{$caller}   = undef;
        $regexen{$caller}   = (ref $regex) ? $regex : qr($regex);
        $callbacks{$caller} = $cback;
    }
}

###########################################################################
# read DATA handle 
# cant do during import as perl hasn't parsed that far by then
##
sub _read_data
{
    my $self = shift;

    if(! defined $modules{$$self})
    {
        my (@data, $data, $tell, $rex, $code, $strip);
        $rex   = delete $regexen{$$self};
        $code  = delete $callbacks{$$self};
        $data  = delete $handles{$$self};

        {
            # slurp and parse...
            no warnings;
            local $/ = undef;
            binmode($data);

            $tell = tell($data);
            Carp::croak("Error: $$self has no __DATA__ section")
                if ($tell < 0);

            my $d = <$data>;
            @data = (ref($rex) eq "CODE") ? $rex->(\$d)  : 
                                            split(/$rex/, $d);
        }

        $modules{$$self} = {} and return 
            unless @data;

        # remove empty elements...depends on syntax used
        shift @data if $data[0]  =~ /^\s*$/o;
        pop   @data if $data[-1] =~ /^\s*$/o;
        Carp::croak("Error: \%$$self\::DATA - bad key/value pairs")
            if (@data % 2);
        

        #  invoke any callbacks...
        if($code)
        {
            for(my $i=0; $i<@data; $i+=2)
            {
                trim(\$data[$i]);
                $_ && $_->(\$data[$i], \$data[$i+1])  
                    foreach @$code;
            }
        }
        
        $modules{$$self} = {@data};     # coerce into hashref and
        delete $modules{$$self}{''};    # remove empty keys
        seek($data, $tell,0);           # cover our tracks
    }
}

###########################################################################
# Utility functions:
# can be used in client code if they want to implement
# their own callback but get default behaviours too
##

sub compress
{
    my $txt = shift;
    $$txt   =~ s#\s+# #sgoi;
    trim($txt);
}

sub block
{
    my $txt = shift;
    #TODO: this could be nicer
    $$txt   =~ s#^(?:$NL\s*$NL)*(.*?)(?:$NL\s*$NL)*$#$/$1$/#soi;
}

sub trim
{
    my $txt = shift;
    for($$txt) {
	   s/^\s+//; s/\s+$//;
    }
}

sub strip
{
    my $txt = shift;
    my $beg = shift || '\#';
    my $end = shift || $NL;
    $$txt =~ s#$NL?$beg.*?$end##sgi;
}

sub interpolate
{
    my $txt  = shift;
    my $vals = shift;
    my $rex  = shift || '\$\((\w+)\)';
    $$txt =~ s#$rex#$vals->{$1}#sg;
}

###########################################################################
# TIE HASH interface (read-only)
# not much to see here...
##

sub TIEHASH 
{
    my $class  = shift;
    my $caller = shift;
    return bless \$caller, $class;
}

sub FETCH 
{
    my $self = shift;
    my $key  = shift;
    $self->_read_data if(! defined $modules{$$self});
    return $modules{$$self}{$key};
}

sub EXISTS
{
    my $self = shift;
    my $key  = shift;
    $self->_read_data if(! defined $modules{$$self});
    return exists $modules{$$self}{$key};
}

sub FIRSTKEY
{
    my $self = shift;
    $self->_read_data if(! defined $modules{$$self});
    my $a = keys %{$modules{$$self}};
    return each %{$modules{$$self}};
}

sub NEXTKEY
{
    my $self = shift;
    $self->_read_data if(! defined $modules{$$self});
    return each %{ $modules{$$self} }
}

sub DESTROY
{
    my $self = shift;
    $modules{$$self} = undef; 
}

sub STORE 
{
    my $self = shift;
    my $k    = shift;
    my $v    = shift;
    #$self->_read_data if(! defined $modules{$$self});
    Carp::croak("Attempt to store key ($k) in read-only hash \%DATA");
}

sub DELETE   
{
    my $self = shift;
    my $k    = shift;
    #$self->_read_data if(! defined $modules{$$self});
    Carp::croak("Attempt to delete key ($k) from read-only hash \%DATA");
}

sub CLEAR    
{
    my $self = shift;
    #$self->_read_data if(! defined $modules{$$self});
    Carp::croak("Attempt to clear read-only hash \%DATA");
}


1;


=pod

=head1 NAME

Text::Embed - Cleanly seperate unwieldy text from your source code

=head1 SYNOPSIS

    use Text::Embed
    use Text::Embed CODE|REGEX|SCALAR
    use Text::Embed CODE|REGEX|SCALAR, LIST

=head1 ABSTRACT

Often, code requires large chunks of text to operate - not large enough 
to add extra file dependencies, but enough to make using quotes and 
heredocs' ugly.

A typical example might be code generators - the text itself is code, 
and as such is difficult to differentiate and maintain when it is 
embedded inside more code. Similarly, CGI scripts often include 
embedded HTML or SQL templates. 

B<Text::Embed> provides the programmer with an flexible way to store 
these portions of text in their namespace's __DATA__ handle - I<away 
from the logic> - and access them through the package variable B<%DATA>. 

=head1 DESCRIPTION

=head2 General Usage:

The general usage is expected to be suitable for a majority of cases.

    use Text::Embed;

    foreach(keys %DATA)
    {
        print "$_ = $DATA{$_}\n";
    }

    print $DATA{foo};



    __DATA__
    
    __foo__

    yadda yadda yadda...

    __bar__

    ee-aye ee-aye oh

    __baz__
    
    woof woof

=head2 Custom Usage:

There are two stages to B<Text::Embed>'s execution - corresponding to the 
first and remaining arguments in its invocation.  

    use Text::Embed ( 
        sub{ ... },  # parse key/values from DATA 
        sub{ ... },  # process pairs
        ...          # process pairs
    );

    ...

    __DATA__

    ...

=head3 Stage 1: Parsing

By default, B<Text::Embed> uses similar syntax to the __DATA__ token to 
seperate segments - a line consisting of two underscores surrounding an
identifier.

Of course, what is suitable depends on the text being embedded, so a 
REGEX or CODE reference can be passed as the first argument - in order 
to gain finer control of how __DATA__ is parsed:

=over 4

=item REGEX

    use Text::Embed qr(<<<<<<<<(\w*?)>>>>>>>>);

A regular expression will be used in a call to C<split()>. Any 
leading or trailing empty strings will be removed automatically.

=item CODE

    use Text::Embed sub{$_ = shift; ...}

A subroutine will be passed a reference to the __DATA__ I<string>. 
It should return a list of key-value pairs.

=back

In the name of laziness, B<Text::Embed> provides a couple of 
predefined formats:

=over 4

=item :define

    #define BAZ 
        baz baz baz
    #define FOO
        foo foo foo
        foo foo foo

=item :cdata

    <![BAZ[baz baz baz]]>
    <![FOO[
        foo foo foo
        foo foo foo
    ]]>

=item :default

    __BAZ__ 
        baz baz baz
    __FOO__
        foo foo foo
        foo foo foo

=back

=head3 Stage 2: Processing

After parsing, each key-value pair can be further processed by an arbitrary
number of callbacks. 

A common usage of this might be controlling how whitespace is represented 
in each segment. B<Text::Embed> provides some likely defaults which operate
on the hash values only:

=over 4

=item :trim

Removes trailing or leading whitespace

=item :compress

Substitutes zero or more whitspace with a single <SPACE>

=item :block

Removes trailing or leading blank lines, preserves indentation

=item :raw

Leave untouched

=item :default

Same as B<:raw>

=back

If comments would make your segments easier to follow, B<Text::Embed> also 
provides some defaults for stripping common comment syntax: 

=over 4

=item :strip-perl

Strips Perl comments

=item :strip-c

Strips C-like comments - C</*...*/>

=item :strip-cpp

Strips both C-like and line-based C<//...> comments

=item :strip-xml

Strips XML/HTML-like comments - C<< <!-- ... --> >>

=back

If you need more control, CODE references or named subroutines can be 
invoked as necessary.

=head3 An Example Callback chain

For the sake of brevity, consider a module that has some embedded SQL. 
We can implement a processing callback that will prepare each statement, 
leaving B<%DATA> full of ready to execute DBI statement handlers: 

    package Whatever;

    use DBI;
    use Text::Embed(':default', ':trim', 'prepare_sql');

    my $dbh;

    sub prepare_sql
    {
        my ($k, $v) = @_;
        if(!$dbh)
        {
            $dbh = DBI->connect(...);
        }
        $$v = $dbh->prepare($$v);
    }

    sub get_widget
    {
        my $id  = shift;
        my $sql = $DATA{select_widget};

        $sql->execute($id);
    
        if($sql->rows)
        {
            ...          
        }
    }
  

    __DATA__
    
    __select_widget__
        SELECT * FROM widgets WHERE widget_id = ?;

    __create_widget__
        INSERT INTO widgets (widget_id,desc, price) VALUES (?,?,?);

    ..etc

Notice that each pair is I<passed by reference>. At this point it is safe 
to rename or modify keys. Undefining a key removes the entry from B<%DATA>.

=head3 Utility Functions

Several utility functions are available to aid implementing custom 
processing handlers. 

The first set are equivalent to the default processing options:

=over 4

=item Text::Embed::trim SCALARREF

    use Text::Embed(':default',':trim');
    use Text::Embed(':default', sub {Text::Embed::trim($_[1]);} );

=item Text::Embed::compress SCALARREF

    use Text::Embed(':default',':compress');
    use Text::Embed(':default', sub {Text::Embed::compress($_[1]);} );

=item Text::Embed::block SCALARREF

    use Text::Embed(':default',':block');
    use Text::Embed(':default', sub {Text::Embed::block($_[1]);} );

=back

Two additional functions are available:

=over 4

=item Text::Embed::strip SCALARREF [REGEX] [REGEX]

If similar behaviour to comment stripping is required in 
a handler, then this function can parse both line-based and 
multi-line comments, depending on its input.

For example, C++ comments are stripped using:

    Text::Embed::strip(\$my_data, '//');
    Text::Embed::strip(\$my_data, '/\*', '\*/');

=item Text::Embed::interpolate SCALARREF HASHREF [REGEX]

Typically, segments may well be some kind of template. This function 
can be used to interpolate values from a hash into the string data. 
The default variable syntax is of the form C<$(foo)>:

    my $tmpl = "Hello $(name)! Your age is $(age)\n";
    my %vars = (name => 'World', age => 4.5 * (10 ** 9));
    
    Text::Embed::interpolate(\$tmpl, \%vars);
    print $tmpl;

Any interpolation is done via a simple substitution. An additional 
regex argument should accomodate this appropriately, by capturing 
the necessary hashkey in C<$1>: 

    Text::Embed::interpolate(\$tmpl, \%vars, '<%(\w+)%>');

=back

=head1 BUGS & CAVEATS

The most likely bugs related to using this module should manifest 
themselves as C<bad key/value> error messages. There are two related 
causes:

=over 4

=item COMMENTS

It is important to realise that B<Text::Embed> does I<not> have its own 
comment syntax or preprocessor. I<Comments should exist in the body of 
a segment - not preceding it>. Any parser that works using C<split()> is 
likely to fail if comments precede the first segment.

=item CUSTOM PARSING

If you are defining your own REGEX parser, make sure you understand 
how it works when used with C<split()> - particularly if your syntax 
wraps your data. Consider using a subroutine for anything non-trivial.

=back

If you employ REGEX parsers, use seperators that are I<significantly> 
different - and well spaced - from your data, rather than relying on
complicated regular expressions to escape pathological cases.

Bug reports and suggestions are most welcome.

=head1 AUTHOR

Copyright (C) 2005 Chris McEwan - All rights reserved.

Chris McEwan <mcewan@cpan.org>

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it 
under the same terms as Perl itself.

=cut

