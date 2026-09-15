import { Transform } from 'class-transformer';
import { IsNotEmpty, IsString, MaxLength } from 'class-validator';
import {
  normalizeUsername,
  PASSWORD_MAX_LENGTH,
  USERNAME_MAX_LENGTH,
} from './credentials';

// Deliberately looser than RegisterDto: the password policy applies when a
// password is chosen, not when it is typed in.
export class PasswordLoginDto {
  @Transform(normalizeUsername)
  @IsString()
  @IsNotEmpty()
  @MaxLength(USERNAME_MAX_LENGTH)
  username!: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(PASSWORD_MAX_LENGTH)
  password!: string;
}
