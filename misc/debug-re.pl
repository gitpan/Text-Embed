#!/usr/bin/perl

BEGIN{ unshift @INC, '../lib'; }

use Text::Embed;



foreach(keys %DATA)
{
    my $string = $DATA{$_};

    if($_ eq "trim")
    {
        Text::Embed::trim(\$string);
    }
    elsif($_ eq "block-preserve")
    {
        Text::Embed::block(\$string);
    }
    elsif($_ eq "block-ignore")
    {
        Text::Embed::block(\$string, 1);
    }
    elsif($_ eq "compress")
    {
        Text::Embed::compress(\$string);
    }

    print "$_ [$string]\n\n"; 
}


__DATA__



__trim__
    


    AAAAAAAAAA AAAAAAAAA AAAAAAAAA



__block-preserve__



    BBBBBBB BBBBBB BBBBBB

    BB BBB
        BB BB

    BBB BB




__block-ignore__



    CCCCC CCCCCC CCCCCCCC

    CCC CC
        C CCC
    
    CCC CC




__compress__



    DDDD DDDDDDDDDDDDDD

    DDDDDDDDDDD DDDDDDD

    DDDDDD  DDDDDDDDD D



