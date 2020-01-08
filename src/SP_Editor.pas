// Copyright (C) 2010 By Paul Dunn
//
// This file is part of the SpecBAS BASIC Interpreter, which is in turn
// part of the SpecOS project.
//
// SpecBAS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// SpecBAS is distributed in the hope that it will be entertaining,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with SpecBAS.  If not, see <http://www.gnu.org/licenses/>.

unit SP_Editor;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}
{$INCLUDE SpecBAS.inc}

interface

Uses Math, SP_SysVars, SysUtils, SP_Util, SP_Graphics, SP_BankManager, SP_Tokenise, SP_Errors, SP_Input,
     Classes, SP_InfixToPostFix, SP_Interpret_PostFix, SP_Variables, SP_Sound, SP_Package, SP_FileIO,
     SP_Graphics32, SP_BankFiling, SP_AnsiStringlist;

Procedure SP_DrawStripe(Dst: pByte; Width, StripeWidth, StripeHeight: Integer);
Procedure SP_EditLoop(Var Error: TSP_ErrorCode);
Function  SP_GetInput(Var Error: TSP_ErrorCode): Boolean;
Procedure SP_PerformINPUT(Char: Byte);
Function  SP_INPUTFromFORMAT: aString;
Function  SP_ShowMenu(Var Options: aString; cX, cY: Integer): Integer;

Var

  EditorSaveFPS: aFloat;

implementation

Uses SP_Main, SP_Menu, SP_FPEditor;

Procedure SP_DrawStripe(Dst: pByte; Width, StripeWidth, StripeHeight: Integer);
Var
  X, Y, X2: Integer;
  Ptr, oPtr: pByte;
Const
  Clrs: Array[0..3] of Byte = (10, 14, 12, 13);
Begin

  X := Width - ((StripeWidth * 4)) - StripeHeight *2;
  oPtr := pByte(NativeUInt(Dst) + (Width * StripeHeight) + X);

  For Y := StripeHeight DownTo 1 Do Begin
    For X2 := X to X + (StripeWidth * 4) -1 Do Begin
      oPtr^ := Clrs[(X2 - X) Div StripeWidth];
      inc(oPtr);
    End;
    Dec(oPtr, Width + (StripeWidth * 4) -1);
  End;

End;

Procedure SP_EditLoop(Var Error: TSP_ErrorCode);
Var
  aSave: Boolean;
  TokensStr, Expr: aString;
  Tokens: paString;
  PreParseErrorCode, PreParseErrorLine, PreParseErrorStatement, CurLine, Idx, LocalFlashState: Integer;
  pInfo: pSP_iInfo;
  Info: TSP_iInfo;
Label
  RunTimeExit;
Begin

  SP_InitFPEditor;

  Info.Error := @Error;
  pInfo := @Info;

  {$IFDEF PANDORA}
  BATTLEVEL := StrToInt(ReadLinuxFile('/sys/class/power_supply/bq27500-0/capacity'));
  {$ELSE}
  BATTLEVEL := 100;
  {$ENDIF}

  SPLITSTATEMENTS := TRUE;
  EDITORWRAP := FALSE;
  SPLITREMS := FALSE;

  SP_FPSetDIsplayColours;

  // Execute the startup code

  aSave := AUTOSAVE;
  AUTOSAVE := False;
  MaxCompileLines := -1;
  MaxDirtyLines := -1;
  If SP_FileExists('s:startup-sequence') Then Begin
    SP_Execute('LOAD "s:startup-sequence": RUN', Error);
    // Clear any errors, as we just ignore them.
    Error.Code := SP_ERR_OK;
  End Else
    If SP_FileExists('startup-sequence') Then Begin
      SP_Execute('LOAD "s:startup-sequence": RUN', Error);
      // Clear any errors, as we just ignore them.
      Error.Code := SP_ERR_OK;
    End;

  SP_FPNewProgram;

  // Startup.
  // Check if the user supplied any parameters. If so, use the first as the mandatory filename,
  // and the second as the optional line number to start from.

  If PCOUNT > 0 Then Begin
    NXTLINE := -1;
    SP_LoadProgram(aString(PARAMS[1]), False, True, nil, Error);
    If Error.Code = SP_ERR_OK Then Begin
      If ParamCount > 1 Then
        CurLine := StrToIntDef(PARAMS[2], -1)
      Else
        CurLine := NXTLINE;
      If CurLine = -1 Then CurLine := 0;
      SP_PreParse(True, Error);
      SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
      SP_Execute('RUN '+IntToString(CurLine), Error);
    End;
    SP_Interpret_QUIT(pInfo);
    Exit;
  End Else Begin

    // Now load the auto-save if it exists, and set up for a NEW error message.

    SP_LoadRecentFiles;

    If aSave And (SP_FileExists('s:autosave')) Then Begin
      SP_LoadProgram('s:autosave', False, False, nil, Error);
      FILENAMED := SP_FileExists(PROGNAME);
    End Else Begin
      SP_Program_Count := 0;
      Error.Line := -2;
      Error.Statement := 0;
      Error.Code := -1;
      NXTLINE := -1;
      NXTSTATEMENT := -1;
      Error.Position := 1;
      PROGNAME := NEWPROGNAME;
      FILENAMED := False;
      SP_PreParse(True, Error);
    End;

    If Not FILENAMED Then SP_SetCurrentDir('/', Error);

    Error.Line := -2;
    Error.Statement := 0;
    Error.Code := -1;
    NXTLINE := -1;
    Error.Position := 1;

  End;

  AUTOSAVE := aSave;
  MOUSEVISIBLE := True;

  SP_FPEditorLoop;
  SP_SaveRecentFiles;

End;

// INPUT routines. Very similar on the face of it to the Editor routines, but with subtle and important differences! Honest!

Function SP_GetInput(Var Error: TSP_ErrorCode): Boolean;
Var
  Finished, Changed: Boolean;
  KeyChar: Byte;
  RepeatLen: LongWord;
  LocalFlashState, Scrolls, Fg, Bg, dCnt: Integer;
  X, Y, PosX, PosY, Top: aFloat;
  EL_Text, TempStr: aString;
Begin

  EditorSaveFPS := FPS;
  SP_SetFPS(EditorFPS);

  Result := False;
  X := 0; Y := 0;

  TempStr := SP_GrabCurrentWindow;

  CURSORFG := INPUTCSR1;
  CURSORBG := INPUTCSR2;
  INPUTLINE := SP_INPUTFromFORMAT;
  CURSORPOS := 1;
  If INFORMAT <> '' Then
    While (CURSORPOS <= Length(INPUTLINE)) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Inc(CURSORPOS);

  SYSTEMSTATE := SS_INPUT;
  Finished := False;
  Changed := True;
  KeyChar := 0;
  RepeatLen := REPDEL;
  LASTKEY := 0;
  Top := Round(PRPOSY);

  While Not Finished Do Begin

    If Changed Then Begin

      EL_Text := INPUTLINE;
      If EL_Text = '' Then Begin
        EL_Text := ' ';
        CURSORPOS := 1;
      End;

      If CURSORPOS = Length(EL_Text) +1 Then
        EL_Text := EL_Text + ' ';

      X := PRPOSX; Y := PRPOSY;
      SCROLLCNT := 0;
      SP_PutCurrentWindow(TempStr);
      If SCREENBPP = 8 Then
        Scrolls := SP_PRINT(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error)
      Else
        Scrolls := SP_PRINT32(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error);
      While Scrolls > 0 Do Begin
        Y := Y - FONTHEIGHT * Scrolls;
        SP_PutCurrentWindow(TempStr);
        If SCREENBPP = 8 Then
          Scrolls := SP_PRINT(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error)
        Else
          Scrolls := SP_PRINT32(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error);
      End;
      SP_SetDirtyRect(0, 0, DISPLAYWIDTH, DISPLAYHEIGHT);
      PRPOSX := X; PRPOSY := Y;
      Changed := False;

    End;

    LocalFlashState := FLASHSTATE;
    Repeat
      If LocalFlashState <> FLASHSTATE Then Begin
        If FlashState = 1 Then Begin
          Fg := CURSORFG; Bg := CURSORBG;
        End Else Begin
          Fg := CURSORBG; Bg := CURSORFG;
        End;
        PosX := PRPOSX; PosY := PRPOSY;
        If SCREENBPP = 8 Then Begin
          SP_TEXTOUT(-1, CURSORX, CURSORY, aChar(CURSORCHAR), Fg, Bg, True);
        End Else Begin
          SP_TEXTOUT32(-1, CURSORX, CURSORY, aChar(CURSORCHAR), Fg, Bg, True);
        End;
        PRPOSX := PosX;
        PRPOSY := PosY;
        LocalFlashState := FLASHSTATE;
      End;
      If QUITMSG Then Exit;
      SP_WaitForSync;
      If LASTKEY = 0 Then KeyChar := 0;
    Until LASTKEY <> 0;

    If LASTKEY in [K_RETURN, K_ESCAPE] Then Begin
      SYSTEMSTATE := SS_IDLE;
      If LASTKEY = K_RETURN Then
        Result := True
      Else Begin
        INPUTLINE := '';
        Result := False;
      End;
      Break;
    End;

    // Is this key the same as the last one?

    If KeyChar = LASTKEY Then Begin

      // Yes - make it repeat if necessary.

      If FRAMES - REPCOUNT >= RepeatLen Then Begin
        RepeatLen := REPPER;
        REPCOUNT := FRAMES;
        SP_PerformINPUT(LASTKEY);
        Changed := True;
      End;

    End Else Begin

      // No - This is a new key

      SP_PerformINPUT(LASTKEY);
      RepeatLen := REPDEL;
      REPCOUNT := FRAMES;
      KeyChar := LASTKEY;
      Changed := True;

    End;

  End;

  SP_PutCurrentWindow(TempStr);
  If SCREENBPP = 8 Then
    Scrolls := SP_PRINT(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error)
  Else
    Scrolls := SP_PRINT32(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error);
  While Scrolls > 0 Do Begin
    Y := Y - FONTHEIGHT * Scrolls;
    SP_PutCurrentWindow(TempStr);
    If SCREENBPP = 8 Then
      Scrolls := SP_PRINT(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error)
    Else
      Scrolls := SP_PRINT32(-1, Round(X), Round(Y), CURSORPOS, EL_Text, T_INK, T_PAPER, Error);
  End;
  SP_SetDirtyRect(0, 0, DISPLAYWIDTH, DISPLAYHEIGHT);
  PRPOSX := X; PRPOSY := Y;
  TempStr := '';

  LASTKEY := 0;

  SP_SetFPS(EditorSaveFPS);

End;

Procedure SP_PerformINPUT(Char: Byte);
Var
  NewChar: Byte;
  LineIdx, Idx, Cnt, LineNum, Statement, PosM, PosT: Integer;
  Error: TSP_ErrorCode;
  nChar: aChar;
Begin

  NewChar := SP_DecodeKey(Char, False);

  If NewChar = 0 Then Begin

    Case Char of

      K_LEFT:
        Begin
          If CURSORPOS > 1 Then Begin
            If (INFORMAT = '') And (KEYSTATE[K_CONTROL] = 1) Then Begin
              If INPUTLINE[CURSORPOS -1] = ' ' Then Dec(CURSORPOS);
              While (CURSORPOS > 1) And (INPUTLINE[CURSORPOS] = ' ') Do Dec(CURSORPOS);
              While (CURSORPOS > 1) and (INPUTLINE[CURSORPOS] <> ' ') Do Dec(CURSORPOS);
              If CURSORPOS > 1 Then
                Inc(CURSORPOS);
            End Else Begin
              Dec(CURSORPOS);
              If INFORMAT <> '' Then Begin
                While (CURSORPOS > 1) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Dec(CURSORPOS);
                If CURSORPOS = 1 Then
                  While (CURSORPOS <= Length(INPUTLINE)) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Inc(CURSORPOS);
              End;
            End;
          End;
        End;

      K_RIGHT:
        Begin
          If CURSORPOS <= Length(INPUTLINE) Then Begin
            If (INFORMAT = '') And (KEYSTATE[K_CONTROL] = 1) Then Begin
              While (CURSORPOS < Length(INPUTLINE)+1) and (INPUTLINE[CURSORPOS] = ' ') Do Inc(CURSORPOS);
              While (CURSORPOS < Length(INPUTLINE)+1) and (INPUTLINE[CURSORPOS] <> ' ') Do Inc(CURSORPOS);
              If INPUTLINE[CURSORPOS] = ' ' Then Inc(CURSORPOS);
            End Else Begin
              Inc(CURSORPOS);
              If INFORMAT <> '' Then Begin
                While (CURSORPOS <= Length(INPUTLINE)) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Inc(CURSORPOS);
                If CURSORPOS = Length(INPUTLINE) Then
                  While (CURSORPOS > 1) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Dec(CURSORPOS);
              End;
            End;
          End;
        End;

      K_HOME:
        Begin
          CURSORPOS := 1;
          If INFORMAT <> '' Then
            While (CURSORPOS <= Length(INPUTLINE)) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Inc(CURSORPOS);
        End;

      K_END:
        Begin
          If INFORMAT <> '' Then Begin
            CURSORPOS := Length(INPUTLINE) +1;
            While (CURSORPOS > 1) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Dec(CURSORPOS);
          End Else
            CURSORPOS := Length(INPUTLINE)+1;
        End;

      K_BACK:
        Begin
          If CURSORPOS > 1 Then Begin
            If INFORMAT = '' Then Begin
              INPUTLINE := Copy(INPUTLINE, 1, CURSORPOS -2) + Copy(INPUTLINE, CURSORPOS, Length(INPUTLINE));
              Dec(CURSORPOS);
            End Else Begin
              Dec(CURSORPOS);
              While (CURSORPOS > 1) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Dec(CURSORPOS);
              If CURSORPOS = 1 Then
                While (CURSORPOS <= Length(INPUTLINE)) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Inc(CURSORPOS);
              INPUTLINE[CURSORPOS] := ' ';
            End;
          End;
        End;

      K_DELETE:
        Begin
          If INFORMAT = '' Then Begin
            If INPUTLINE <> '' Then Begin
              If CURSORPOS <= Length(INPUTLINE) Then
                INPUTLINE := Copy(INPUTLINE, 1, CURSORPOS -1) + Copy(INPUTLINE, CURSORPOS +1, Length(INPUTLINE));
            End;
          End Else Begin
            INPUTLINE[CURSORPOS] := ' ';
          End;
        End;

      K_INSERT:
        Begin
          If INFORMAT = '' Then
            INSERT := Not INSERT;
        End;

      K_ESCAPE:
        Begin
          INPUTLINE := '';
        End;

    End;

    If CURSORPOS > Length(INPUTLINE) Then
      CURSORCHAR := 32
    Else
      CURSORCHAR := Ord(INPUTLINE[CURSORPOS]);

  End Else Begin

    IF INFORMAT = '' Then Begin
      If KEYSTATE[K_CONTROL] = 1 Then Begin
        If INSERT Then Begin
          INPUTLINE := Copy(INPUTLINE, 1, CURSORPOS -1) + aChar(Byte(NewChar) + 128) + Copy(INPUTLINE, CURSORPOS, Length(INPUTLINE));
          Inc(CursorPos, 2);
        End Else Begin
          INPUTLINE := Copy(INPUTLINE, 1, CURSORPOS -1) + aChar(Byte(NewChar) + 128) + Copy(INPUTLINE, CURSORPOS +1, LENGTH(INPUTLINE));
          Inc(CURSORPOS, 2);
        End;
      End Else Begin
        If INSERT Then
          INPUTLINE := Copy(INPUTLINE, 1, CURSORPOS -1) + aChar(NewChar) + Copy(INPUTLINE, CURSORPOS, Length(INPUTLINE))
        Else Begin
          INPUTLINE := Copy(INPUTLINE, 1, CURSORPOS -1) + aChar(NewChar) + Copy(INPUTLINE, CURSORPOS +1, LENGTH(INPUTLINE));
        End;
        Inc(CURSORPOS);
      End;
    End Else If CURSORPOS <= Length(INPUTLINE) Then Begin
      nChar := aChar(NewChar);
      If INFORMAT[(CURSORPOS *2) -1] <> '\' Then
        Case INFORMAT[CURSORPOS *2] of
          'A':
            If nChar in ['a'..'z'] Then
              nChar := aChar(Ord(nChar) - 32)
            Else
              If Not (nChar in ['A'..'Z']) Then
                nChar := #0;
          'a':
            If nChar in ['A'..'Z'] Then
              nChar := aChar(Byte(nChar) + 32)
            Else
              If Not (nChar in ['a'..'z']) Then
                nChar := #0;
          '#':
            If Not (nChar in ['0'..'9']) Then
              nChar := #0;
          '<':
            If nChar in ['A'..'Z'] Then
              nChar := aChar(Ord(nChar) + 32);
          '>':
            If nChar in ['a'..'z'] Then
              nChar := aChar(Ord(nChar) - 32);
          '&':
            If Not (nChar in ['A'..'Z', 'a'..'z']) Then
              nChar := #0;
          '?':
            If Not (nChar in ['A'..'Z', 'a'..'z', '0'..'9']) Then
              nChar := #0;
        End;
      If nChar <> #0 Then Begin
        INPUTLINE := Copy(INPUTLINE, 1, CURSORPOS -1) + nChar + Copy(INPUTLINE, CURSORPOS +1, LENGTH(INPUTLINE));
        If CURSORPOS <= Length(INPUTLINE) Then Begin
          Inc(CURSORPOS);
          While (CURSORPOS <= Length(INPUTLINE)) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Inc(CURSORPOS);
          If CURSORPOS = Length(INPUTLINE) Then
            While (CURSORPOS > 1) And Not ((INFORMAT[CURSORPOS *2] in ['#', 'A', 'a', '<', '>', '&', '?', '*']) And (INFORMAT[(CURSORPOS *2)-1] <> '\')) Do Dec(CURSORPOS);
        End;
      End;
    End;

  End;

End;

Function SP_INPUTFromFORMAT: aString;
Var
  Idx: Integer;
Begin

  Result := '';

  Idx := 1;
  While Idx <= Length(INFORMAT) -2 Do Begin

    Case INFORMAT[Idx] Of
      '#', 'A', 'a', '<', '>', '&', '?', '*':
        Result := Result + ' ';
      '\':
        Begin
          Result := Result + INFORMAT[Idx +1];
        End;
    Else
      Result := Result + INFORMAT[Idx];
    End;

    Inc(Idx, 2);

  End;

End;

// Message box routines - info boxes, 128k-style menus etc

Function  SP_ShowMenu(Var Options: aString; cX, cY: Integer): Integer;
Var
  NumOptions, MaxWidth, WinX, WinY, WinW, WinH, Offset, Idx, StrLen,
  Window, WindowID, yOff, CurOption, RepeatLen, bWidth, bHeight, fW, fH: Integer;
  OptionList: TAnsiStringList;
  cBlack, cWhite, cRed, cGreen, cCyan, cYellow, KeyChar: Byte;
  Err: TSP_ErrorCode;
  Win: pSP_Window_Info;
  Done: Boolean;
Begin

  EditorSaveFPS := FPS;
  SP_SetFPS(EditorFPS);

  KeyChar := 0;
  RepeatLen := 0;
  Result := -1;

  // Options in the string, in format length,string...
  // Centre the box on cX, cY in the current window.

  NumOptions := pLongWord(@Options[1])^;
  Optionlist := TAnsiStringList.Create;

  MaxWidth := 0;
  Offset := SizeOf(LongWord) +1;
  For Idx := 1 To NumOptions Do Begin
    StrLen := pLongWord(@Options[Offset])^;
    OptionList.Add(Copy(String(Options), Offset + SizeOf(LongWord), StrLen));
    Inc(Offset, SizeOf(LongWord) + StrLen);
    If StrLen > MaxWidth Then
      MaxWidth := StrLen;
  End;

  // Now calculate the metrics of the window that we'll need
  // Width - one pixel border, FONTWIDTH-1 pixels space, text, FONTWIDTH-1 pixels space one pixel border
  // Height - one pixel border, optional title + one pixel separator, 4 pixels space, text, 4 pixels space, one pixel border.

  fW := FONTWIDTH;
  fH := FONTHEIGHT;

  bWidth := fW Div 2;
  bHeight := fH Div 2;
  If OptionList[0] <> '' Then Begin
    WinW := Max(((7 + Length(OptionList[0])) * fW) + bWidth, Min(DISPLAYWIDTH, (MaxWidth * fW) + (bWidth * 2) + 2));
    WinH := Min(DISPLAYHEIGHT, (NumOptions * fH) + (bHeight * 2) + 3);
  End Else Begin
    WinW := Min(DISPLAYWIDTH, (MaxWidth * fW) + (bWidth * 2) + 2);
    WinH := Min(DISPLAYHEIGHT, ((NumOptions -1) * fH) + (bHeight * 2) + 2);
  End;

  // Convert the cX,cY centre values to display space, as the menu uses a window, and thus the display coordinates.

  Inc(cX, SCREENX);
  Inc(cY, SCREENY);
  WinX := cX - (WinW Div 2);
  WinY := cY - (WinH Div 2);
  If WinX + WinW > DISPLAYWIDTH Then
    WinX := (DISPLAYWIDTH + WinW) Div 2;
  If WinY + WinH > DISPLAYHEIGHT Then
    WinY := (DISPLAYHEIGHT + WinH) Div 2;

  // Because we're not using the editor's technique of hijacking the palette, we need to choose
  // appropriate palette entries for this.

  cBlack := SP_Get_Nearest_Colour(0, 0, 0, -1);
  cRed := SP_Get_Nearest_Colour(255, 0, 0, -1);
  cGreen := SP_Get_Nearest_Colour(0, 255, 0, -1);
  cCyan := SP_Get_Nearest_Colour(0, 255, 255, -1);
  cYellow := SP_Get_Nearest_Colour(255, 255, 0, -1);
  cWhite := SP_Get_Nearest_Colour(255, 255, 255, -1);

  // Now create the window

  Window := SCREENBANK;
  WindowID := SP_Add_Window(WinX, WinY, WinW, WinH, -1, 8, 0, Err);
  SP_GetWindowDetails(WindowID, Win, Err);
  SP_SetDrawingWindow(WindowID);
  For Idx := 0 To 255 Do pSP_Window_Info(WINDOWPOINTER)^.Palette[Idx] := DefaultPalette[Idx];

  // And draw the menu.

  T_INK := cBlack;
  SP_FillRect(0, 0, WinW, WinH, cWhite);
  SP_DrawRectangle(0, 0, WinW -1, WinH -1);

  If OptionList[0] <> '' Then Begin

    SP_FillRect(0, 0, WinW, fH + 2, cBlack);
    SP_TextOut(-1, 1, 1, aString(OptionList[0]), 15, 0, True);
    SP_DrawStripe(@SP_BankList[SP_FindBankID(SCREENBANK)]^.Memory[0], Win^.Width, fW, fH);
    yOff := bHeight + 2;

  End Else

    yOff := (bHeight +1) - fH;

  // Now enter the main loop, drawing the options and waiting/responding on user input.
  // Allowed keys are up/down/enter/escape/home/end. Mouse may also be used, if the mouse is currently visible.
  // This is a modified version of the routines used by the INPUT systems above.

  Done := False;
  CurOption := 1;
  LASTKEY := 0;
  Repeat

    For Idx := 1 to OptionList.Count -1 Do Begin
      If Idx = CurOption Then Begin
        SP_FillRect(bWidth +1, yOff + (Idx * fH), WinW - ((bWidth * 2) + 2), fH, cCyan);
        SP_TextOut(-1, bWidth +1, yOff + (Idx * fH), aString(OptionList[Idx]), cBlack, cCyan, True)
      End Else Begin
        SP_FillRect(bWidth +1, yOff + (Idx * fH), WinW - ((bWidth * 2) + 2), fH, cWhite);
        SP_TextOut(-1, bWidth +1, yOff + (Idx * fH), aString(OptionList[Idx]), cBlack, cWhite, True);
      End;
    End;

    Repeat
      CB_Yield;
      If LASTKEY = 0 Then KeyChar := 0;
    Until (LASTKEY <> 0) or QUITMSG;
    If QUITMSG Then Exit;

    If LASTKEY in [K_RETURN, K_ESCAPE] Then Begin
      If LASTKEY = K_RETURN Then
        Result := integer(BASE) + CurOption -1
      Else Begin
        Result := -1;
      End;
      Done := True;
    End Else

      // Is this key the same as the last one?

      If KeyChar = LASTKEY Then Begin

        // Yes - make it repeat if necessary.

        If FRAMES - REPCOUNT >= LongWord(RepeatLen) Then Begin
          RepeatLen := REPPER;
          REPCOUNT := FRAMES;
          Case LASTKEY of
            K_UP:
              If CurOption > 1 Then Dec(CurOption) Else CurOption := Numoptions -1;
            K_DOWN:
              If CurOption < NumOptions -1 Then Inc(CurOption) Else CurOption := 1;
            K_HOME:
              CurOption := 1;
            K_END:
              CurOption := NumOptions -1;
          End;
          SP_PlaySystem(CLICKCHAN, CLICKBANK);
        End;

      End Else Begin

        // No - This is a new key

        Case LASTKEY of
          K_UP:
            If CurOption > 1 Then Dec(CurOption) Else CurOption := Numoptions -1;
          K_DOWN:
            If CurOption < NumOptions -1 Then Inc(CurOption) Else CurOption := 1;
          K_HOME:
            CurOption := 1;
          K_END:
            CurOption := NumOptions -1;
        End;
        SP_PlaySystem(CLICKCHAN, CLICKBANK);
        RepeatLen := REPDEL;
        REPCOUNT := FRAMES;
        KeyChar := LASTKEY;

      End;

  Until Done;

  SCREENBANK := -1;
  SP_SetDrawingWindow(Window);
  SP_DeleteWindow(WindowID, Err);
  OptionList.Free;

  SP_SetFPS(EditorSaveFPS);

End;

end.
