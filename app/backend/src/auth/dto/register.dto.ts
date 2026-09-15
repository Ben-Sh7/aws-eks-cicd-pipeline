import { Transform } from 'class-transformer';
import {
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import {
  normalizeUsername,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  trim,
  USERNAME_PATTERN,
} from './credentials';

export class RegisterDto {
  @Transform(normalizeUsername)
  @IsString()
  @Matches(USERNAME_PATTERN, {
    message:
      'username must be 3-32 letters, digits, dots, dashes or underscores, starting and ending with a letter or digit',
  })
  username!: string;

  // Never trimmed or otherwise transformed: every character typed counts.
  @IsString()
  @MinLength(PASSWORD_MIN_LENGTH)
  @MaxLength(PASSWORD_MAX_LENGTH)
  password!: string;

  @IsOptional()
  @Transform(trim)
  @IsString()
  @MaxLength(100)
  name?: string;
}
