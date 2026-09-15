import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Post,
  UnauthorizedException,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { UsersService } from '../users/users.service';
import { AuthService, type AuthTokens } from './auth.service';
import { type AuthenticatedUser, CurrentUser } from './current-user.decorator';
import { GoogleLoginDto } from './dto/google-login.dto';
import { PasswordLoginDto } from './dto/password-login.dto';
import { RefreshTokenDto } from './dto/refresh-token.dto';
import { RegisterDto } from './dto/register.dto';
import { Public } from './public.decorator';

// Stricter than the global limit: these endpoints are what an attacker probes.
const AUTH_THROTTLE = { default: { limit: 20, ttl: 60_000 } };

export interface UserProfile {
  id: string;
  username: string | null;
  email: string | null;
  name: string | null;
  avatarUrl: string | null;
}

@Controller('auth')
export class AuthController {
  constructor(
    private readonly authService: AuthService,
    private readonly usersService: UsersService,
  ) {}

  @Public()
  @Throttle(AUTH_THROTTLE)
  @Post('google')
  @HttpCode(HttpStatus.OK)
  loginWithGoogle(@Body() dto: GoogleLoginDto): Promise<AuthTokens> {
    return this.authService.loginWithGoogle(dto.idToken);
  }

  @Public()
  @Throttle(AUTH_THROTTLE)
  @Post('register')
  @HttpCode(HttpStatus.CREATED)
  register(@Body() dto: RegisterDto): Promise<AuthTokens> {
    return this.authService.register(dto);
  }

  @Public()
  @Throttle(AUTH_THROTTLE)
  @Post('login')
  @HttpCode(HttpStatus.OK)
  loginWithPassword(@Body() dto: PasswordLoginDto): Promise<AuthTokens> {
    return this.authService.loginWithPassword(dto.username, dto.password);
  }

  @Public()
  @Throttle(AUTH_THROTTLE)
  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  refresh(@Body() dto: RefreshTokenDto): Promise<AuthTokens> {
    return this.authService.refresh(dto.refreshToken);
  }

  // Public because it is called exactly when the access token may have
  // expired; possession of the refresh token is the authorisation.
  @Public()
  @Post('logout')
  @HttpCode(HttpStatus.NO_CONTENT)
  logout(@Body() dto: RefreshTokenDto): Promise<void> {
    return this.authService.logout(dto.refreshToken);
  }

  @Get('me')
  async me(@CurrentUser() user: AuthenticatedUser): Promise<UserProfile> {
    const found = await this.usersService.findById(user.id);
    if (!found) {
      throw new UnauthorizedException();
    }
    return {
      id: found.id,
      username: found.username,
      email: found.email,
      name: found.name,
      avatarUrl: found.avatarUrl,
    };
  }
}
