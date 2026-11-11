import { expect, it } from 'vitest'
import { double } from './double'

it('doubles', () => {
  expect(double(2)).toEqual(4)
})
